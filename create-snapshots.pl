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
use Getopt::Long;

use constant PFEXEC => '/usr/bin/pfexec';
use constant ZFS    => '/usr/sbin/zfs';

STDOUT->autoflush(1);

main();

sub main {

    # parse options
    my %opt;
    GetOptions(
        \%opt,
        't=s',
    ) or usage();

    # snapshot type is either 'backup', 'daily', or 'frequent'
    usage() if !exists $opt{t};
    my $snapshot_type = $opt{t};

    # get all filesystmes and volumes which we want to create a snapshot on
    open my $fh, '-|', ZFS, qw(list -H -o name,ch.kzone:zfs-snapshot) or die "Cannot run zfs list: $!";
    my @lines = <$fh>;
    close $fh or die "Cannot run zfs list: $!";

    chomp @lines;
    my %filesystem_or_volumes;
    for my $filesystem_or_volume ( map { $_->[0] } grep { $_->[1] eq 'on' } map { [ split /\t/, $_, 2 ] } @lines ) {
        $filesystem_or_volume =~ m{ \A ( [^/]+ ) }xsm or die;
        my $pool = $1;
        push @{ $filesystem_or_volumes{$pool} }, $filesystem_or_volume;
    }

    # calculate the snapshot prefix, if any - only 'backup' snapshots have one
    my $snapshot_name_prefix = q{};
    if ( $snapshot_type eq 'backup' ) {
        open my $fh, '-|', 'hostname', '-s' or die "Cannot obtain hostname: $!";
        my ($hostname) = <$fh>;
        close $fh or die "Cannot obtain hostname: $!";
        chomp $hostname;

        if ( $hostname eq 'adarak-new' ) {
            $hostname = 'adarak';
        }

        $snapshot_name_prefix = "__backup__";
    }

    # read the base URL to update Update Kuma from config file
    my $kuma_base_file = File::Spec->catdir( File::Basename::dirname( Cwd::abs_path __FILE__ ), 'kuma-base' );
    undef $fh;
    open $fh, '<', $kuma_base_file or die "Cannot read $kuma_base_file: $!";
    my ($kuma_base) = <$fh>;
    close $fh or die "Cannot read $kuma_base_file: $!";
    chomp $kuma_base;

    # ZFS cannot create snapshots atomically over multiple pools, we have to
    # run one 'zfs snapshot' call per pool
    my $ok = 1;
    for my $pool ( sort keys %filesystem_or_volumes ) {
        my @snapshots;
        my $snapshot_name;
        if ( $snapshot_type eq 'backup' ) {
            my ( $mday, $mon, $year ) = ( localtime(time) )[ 3 .. 5 ];
            $snapshot_name = sprintf '%s%04i-%02i-%02i', $snapshot_name_prefix, ( $year + 1900 ), ( $mon + 1 ), $mday;
        }
        elsif ( $snapshot_type eq 'daily' || $snapshot_type eq 'frequent' ) {
            my ( $sec, $min, $hour, $mday, $mon, $year ) = ( gmtime(time) )[ 0 .. 5 ];
            $snapshot_name = sprintf '%s%04i-%02i-%02i-%02i%02i%02iZ', $snapshot_name_prefix, ( $year + 1900 ), ( $mon + 1 ), $mday, $hour, $min, $sec;
        }
        else {
            die "unknown snapshot type: $snapshot_type";
        }

        for my $filesystem_or_volume ( @{ $filesystem_or_volumes{$pool} } ) {
            push @snapshots, sprintf '%s@%s', $filesystem_or_volume, $snapshot_name;
        }

        system( PFEXEC, ZFS, 'snapshot', '-o', "ch.kzone:zfs-snapshot-type=$snapshot_type", @snapshots ) == 0 or do {
            warn "Creating snapshots failed";

            curl("${kuma_base}?status=down&msg=could%20not%20create%20snapshots");
            $ok = 0;
        }
    }

    exit 1 if !$ok;

    curl("${kuma_base}?status=up&msg=OK");
    exit 0;
}

sub usage {
    die "usage: $0 -t < backup | daily | frequent >\n";
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
