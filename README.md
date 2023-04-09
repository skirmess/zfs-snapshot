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



## Snapshot Pruning
