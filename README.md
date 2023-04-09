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

## Existing tools



## Snapshot Creation



## Snapshot Pruning
