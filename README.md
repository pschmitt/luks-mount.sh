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
