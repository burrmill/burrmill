The etc/ directory is for the user
==================================

We won't ever overwrite files here. This directory is for your use only.

When you invoke `bm-update-project`, files from the `lib/skel` directory are
copied here. We expect you to check them in into your own repository, and modify
them as you see fit. We never overwrite them.

If you run `bm-update-project` again (you can run it multiple times; it will
only fix inconsistencies in configuration and won't overwrite anything), _new_
files added to the `lib/skel`, if any, will be copied here. However, they are
either entirely commented out, or just not used by BurrMill unless you tell it
so (how exactly, depends on the file and its function).

_We very highly recommend you to use source control on your configuration._ GCP
offers code repositories for private work, up to five for free, or use GitHub if
you want to publish your work. Please consider sending us a PR against core
BurrMill files instead, if you think the work will be of interest to the
community.
