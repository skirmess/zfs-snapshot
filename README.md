## Requirements

### No Prefix Like daily\_ or hourly\_

This prefix bears no value for what the snapshot contains and is only used for deciding when to destroy them.

A better way would be to set a user property on the snapshot itself. This has the added benefit of ensuring we never destroy a third party snapshot, even if we use a wrong pattern to find snapshots to prune.

User properties can be set on the snapshot during its creation like so:

```sh
$ pfexec zfs snapshot -o ch.kzone.snapshot:type=daily rpool/home@2023-04-09_155300Z
```

### Atomic Snapshots

ZFS supports atomic snapshots, there is no good reason to not create atomic snapshots.

### Keep Snapshots by Number and Date

Don't just expire them all if you boot an old system that wasn't powered on for 6 month.

## Existing Tools

### [zrepl](https://github.com/zrepl/zrepl)

- does not create atomic snapshots [#634](https://github.com/zrepl/zrepl/issues/634)
- cannot create different types of snapshots
- expiration is smart but doesn't give us enough control [#691](https://github.com/zrepl/zrepl/issues/691), [#692](https://github.com/zrepl/zrepl/issues/692), [#693](https://github.com/zrepl/zrepl/issues/693)
- cannot create snapshots without a prefix [#694](https://github.com/zrepl/zrepl/issues/694)
- no status output to check if all snapshots were created correctly [Comment 1841410](https://github.com/zrepl/zrepl/discussions/547#discussioncomment-1841410)

### [Sanoid](https://github.com/jimsalterjrs/sanoid)

- uses snapshot names like daily\_ and hourly\_
- makes it complicated to change the retention policy at a later time because the retention is part of the snapshot name when it is created. (e.g. you can't easily switch from 365 daily to 52 weekly snapshots without manually renaming them)

### [zfsnap](https://github.com/zfsnap/zfsnap)

- project is unmaintained [#109](https://github.com/zfsnap/zfsnap/issues/109)

## Snapshot Creation

We will create backup snapshots named `\_\_backup\_\_HOSTNAME\_\_2023-03-25` and short lived snapshots named `2023-04-09_161500Z`.

### Backup Snapshot

Create one backup snapshot on Monday at 1:55 local time. This backup will be transfered to a backup server for long time archiving.

### Daily Snapshot

Create a daily snapshot at 02:00 local time. These snapshots will not be expired on date but we will always keep at least 35 of them. We set the `ch.kzone.snapshot:type=daily` property on the snapshot to easily find them.

### Frequent Snapshot

Create a frequent snapshot every 15 minutes from 12:00 until 01:45. These snapshots will be expired after 24 hours. We set the `ch.kzone.snapshot:type=frequent` property.

## Snapshot Pruning

### Backup Server

No pruning on backup server. We only transfer the backup snapshots and keep them forever (one per week will result in 1000 snapshots for 20 years, this should work out for now).

### Server

- frequent snapshots are destroyed after 24 hours

We probably run the prune script only once during the night, which means the snapshots can exist for a bit more than 24 hours.

- daily snapshot

Count them and remove all but the last 35 daily snapshots.

- backup snapshots

We need to ensure that the backup snapshots are kept on the server until they are successfully transfered to the backup server.
