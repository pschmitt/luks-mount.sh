# luks-mount.sh

This is a dirty-ass script to mount a luks-encrypted removable device.

# Installation

Dependencies:

- [yq](https://github.com/mikefarah/yq)

Then all you need to do is grab [luks-mount.sh](luks-mount.sh) and point it to
[your configuration file](./sample-config.yaml):

```shell
./luks-mount.sh --config /path/to/config.yaml
```

# Configuration

See [the config file](./sample-config.yaml) for how to set this up.

Passphrases can be provided interactively via stdin, or by environment variables
such as `LUKS_PASSPHRASE_${DEVICE_NAME}`.

For the [sample config](./sample-config.yaml) this would be
`LUKS_PASSPHRASE_DATA`.
