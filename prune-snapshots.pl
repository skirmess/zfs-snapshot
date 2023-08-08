#!/usr/bin/env perl

# vim: ts=4 sts=4 sw=4 et: syntax=perl
#
# Copyright (c) 2023 Sven Kirmess
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

use 5.010;
use strict;
use warnings;
no warnings 'qw';

use Cwd            ();
use File::Basename ();
use File::Spec     ();
use FileHandle     ();

use constant NUM_DAILY_TO_KEEP         => 35;
use constant SECONDS_TO_KEEP_FREQUENTS => 24 * 60 * 60;
use constant FREQUENTS_CUT_OFF_TIME    => time() - SECONDS_TO_KEEP_FREQUENTS;
use constant BACKUPS_TO_KEEP           => 3;

use constant SNAPSHOT_DEBUG_FORMAT => '%-11s %-8s %s';

use constant PFEXEC => '/usr/bin/pfexec';
use constant ZFS    => '/usr/sbin/zfs';

STDOUT->autoflush(1);

main();

sub main {
    usage() if !@ARGV;

    if ( $ARGV[0] eq 'prune' ) {
        usage() if @ARGV != 1;

        # read the base URL to update Update Kuma from config file
        my $kuma_base_file = File::Spec->catdir( File::Basename::dirname( Cwd::abs_path __FILE__ ), 'kuma-base-prune' );
        open my $fh, '<', $kuma_base_file or die "Cannot read $kuma_base_file: $!";
        my ($kuma_base) = <$fh>;
        close $fh or die "Cannot read $kuma_base_file: $!";
        chomp $kuma_base;

        # get all filesystmes and volumes which we want to prune a snapshot on
        undef $fh;
        open $fh, '-|', ZFS, qw(list -H -o name,ch.kzone:zfs-snapshot) or die "Cannot run zfs list: $!";
        my @lines = <$fh>;
        close $fh or die "Cannot run zfs list: $!";

        chomp @lines;
        my @filesystem_or_volumes = map { $_->[0] } grep { $_->[1] eq 'on' } map { [ split /\t/, $_, 2 ] } @lines;

        my $num_pruned = 0;
        my $ok         = 1;
        for my $filesystem_or_volume (@filesystem_or_volumes) {
            my @to_prune = prune_snapshots( $filesystem_or_volume, 0 );
            $num_pruned += scalar @to_prune;

            while (@to_prune) {
                my @to_prune_now = splice @to_prune, 0, 50;
                if ( !zfs_destroy(@to_prune_now) ) {
                    curl("${kuma_base}?status=down&msg=could%20not%20destroy%20snapshots");
                    $ok = 0;
                }
            }
        }

        exit 1 if !$ok;

        curl("${kuma_base}?status=up&msg=OK");

        exit 0;
    }

    if ( $ARGV[0] eq 'show' ) {
        usage() if @ARGV != 2;

        my $filesystem_or_volume = $ARGV[1];
        prune_snapshots( $filesystem_or_volume, 1 );

        exit 0;
    }

    usage();
}

sub usage {
    die "usage: $0 show <snapshot>\n"
      . "       $0 prune\n";
}

sub prune_snapshots {
    my ( $filesystem_or_volume, $debug ) = @_;

    # get guid of FS
    open my $fh, '-|', ZFS, qw(get -Hp guid), $filesystem_or_volume or die "Cannot get guid from $filesystem_or_volume: $!";
    my @lines = <$fh>;
    close $fh or die "Cannot get snapshots from $filesystem_or_volume: $!";
    chomp @lines;
    die if @lines != 1;
    die if $lines[0] !~ m{ \A \Q$filesystem_or_volume\E \t guid \t ( [1-9][0-9]*) \t }xsm;
    my $guid = $1;

    #
    my @to_prune;

    open $fh, '-|', ZFS, qw(list -Hp -t snapshot -d 1 -o name,creation,ch.kzone:zfs-snapshot-type), $filesystem_or_volume or die "Cannot get snapshots from $filesystem_or_volume: $!";
    @lines = <$fh>;
    close $fh or die "Cannot get snapshots from $filesystem_or_volume: $!";

    chomp @lines;

    my @debug;

    my $check_backup = check_backup($filesystem_or_volume, $guid);

    my $daily_seen = 0;
  LINE:
    for my $line ( reverse @lines ) {
        my ( $name, $creation, $type ) = split /\t/, $line, 3;

        if ( $type eq q{-} ) {
            push @debug, sprintf SNAPSHOT_DEBUG_FORMAT, 'KEEP', 'OTHER', $name;
            next LINE;
        }

        if ( $type eq 'backup' ) {
            my ( $can_delete, $msg) = $check_backup->($name);

            if ( $can_delete ) {
                push @to_prune, $name;
                push @debug, sprintf SNAPSHOT_DEBUG_FORMAT, "PRUNE $msg", $type, $name;
            }
            else {
                push @debug, sprintf SNAPSHOT_DEBUG_FORMAT, "KEEP $msg", $type, $name;
            }

            next LINE;
        }

        if ( $type eq 'daily' ) {
            $daily_seen++;

            if ( $daily_seen > NUM_DAILY_TO_KEEP ) {
                push @to_prune, $name;
                push @debug, sprintf SNAPSHOT_DEBUG_FORMAT, 'PRUNE', $type, $name;
            }
            else {
                push @debug, sprintf SNAPSHOT_DEBUG_FORMAT, "KEEP $daily_seen/" . NUM_DAILY_TO_KEEP, $type, $name;
            }

            next LINE;
        }

        if ( $type eq 'frequent' ) {
            if ( $creation < FREQUENTS_CUT_OFF_TIME ) {
                push @to_prune, $name;
                push @debug, sprintf SNAPSHOT_DEBUG_FORMAT, 'PRUNE', $type, $name;
            }
            else {
                push @debug, sprintf SNAPSHOT_DEBUG_FORMAT, 'KEEP', $type, $name;
            }

            next LINE;
        }

        die "Unknown type '$type' for snapshot '$name'";
    }

    if ($debug) {
        for my $line ( reverse @debug ) {
            say $line;
        }
    }

    return @to_prune;
}

sub check_backup {
    my ($filesystem_or_volume, $guid) = @_;

    my $bynaus_file_name = "/home/admin/backup/bynaus.${guid}.txt";
    my $corinth_file_name = "/home/admin/backup/corinth.${guid}.txt";

    my %bynaus_backed_up;
    my %bynaus_backed_up_and_keep;
    my %corinth_backed_up;
    my %corinth_backed_up_and_keep;

  SNAP:
    for my $snap ( reverse _check_backup_load_file($bynaus_file_name, $filesystem_or_volume, $guid) ) {
        if ( scalar keys %bynaus_backed_up_and_keep < 3 ) {
            $bynaus_backed_up_and_keep{$snap} = 1;
            next SNAP;
        }
        $bynaus_backed_up{$snap} = 1;
    }

  SNAP:
    for my $snap ( reverse _check_backup_load_file($corinth_file_name, $filesystem_or_volume, $guid) ) {
        if ( scalar keys %corinth_backed_up_and_keep < BACKUPS_TO_KEEP ) {
            $corinth_backed_up_and_keep{$snap} = 1;
            next SNAP;
        }
        $corinth_backed_up{$snap} = 1;
    }

    return sub {
        my ($snap) = @_;

        my $result;
        my $can_delete = 1;
        if ( exists $bynaus_backed_up_and_keep{$snap} ) {
            $result .= "B!";
            $can_delete = 0;
        }
        elsif ( exists $bynaus_backed_up{$snap} ) {
            $result .= "B+";
        }
        else {
            $result .= "B-";
            $can_delete = 0;
        }

        $result .= q{ };

        if ( exists $corinth_backed_up_and_keep{$snap} ) {
            $result .= "C!";
            $can_delete = 0;
        }
        elsif ( exists $corinth_backed_up{$snap} ) {
            $result .= "C+";
        }
        else {
            $result .= "C-";
            $can_delete = 0;
        }

        return($can_delete, $result);
    };
}

sub _check_backup_load_file {
    my ($file, $name, $guid) = @_;

    return if !-f $file;

    open my $fh, '<', $file or die "Cannot read file $file: $!";

    my $line = <$fh>;
    chomp $line;
    die "File $file is corrupt: invalid name: $line" if $line ne "NAME $name";

    $line = <$fh>;
    chomp $line;
    die "File $file is corrupt: invalid guid: $line" if $line ne "GUID $guid";

    my $end_seen = 0;
    my @snaps;
  LINE:
    while (defined (my $line = <$fh>)) {
        die "Content after end: $line" if $end_seen;
        chomp $line;

        if ( $line eq 'END' ) {
            $end_seen = 1;
            next LINE;
        }

        die "Corrupt file $file: unexpected $line" if $line !~ m{ \A SNAP \s ( __backup__ [12][0-9][0-9][0-9] - [01][0-9] - [0-3][0-9] ) \z }xsm;
        push @snaps, "$name\@$1";
        next LINE;
    }

    die "File $file is corrupt: end not seen" if !$end_seen;

    close $fh or die "Cannot read file $file: $!";

    return @snaps;
}

sub curl {
    my ($url) = @_;

    if ( open my $fh, '-|', qw(curl -k --fail-with-body --no-progress-meter), $url ) {
        my @lines = <$fh>;

        my $ok = 1;
        if ( !close($fh) ) {
            $ok = 0;
        }
        if ( $? != 0 ) {
            $ok = 0;
        }

        return if $ok;

        warn join q{}, @lines;
    }

    warn "Cannot get $url: $!";
    return;
}

sub zfs_destroy {
    my (@snapshots) = @_;

    die if !@snapshots;
    my $to_delete = shift @snapshots;
    if (@snapshots) {
        die if $to_delete !~ m{ \A ( [^@]+ ) [@] [^@]+ \z }xsm;
        my $dataset = $1;

        for my $snapshot (@snapshots) {
            $snapshot =~ s{ \A \Q$dataset\E [@] }{}xsm or die "snapshot: $snapshot; dataset: $dataset";
            $to_delete .= ",$snapshot";
        }
    }

    die if $to_delete !~ m{ [@] }xsm;

    if ( open my $fh, '-|', PFEXEC, ZFS, 'destroy', $to_delete ) {
        my @lines = <$fh>;

        my $ok = 1;
        if ( !close($fh) ) {
            $ok = 0;
        }
        if ( $? != 0 ) {
            $ok = 0;
        }

        return 1 if $ok;

        warn join q{}, @lines;
    }

    warn 'Cannot destroy snapshots';
    return;
}
