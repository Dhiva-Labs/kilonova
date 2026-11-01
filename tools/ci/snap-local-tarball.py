#!/usr/bin/env python3
"""Point the snap at a Linux tarball built in this run.

snap/snapcraft.yaml downloads the tarball of a published release and checks
it against a recorded checksum. The Release workflow cannot do that before a
release exists (and an architecture's first tarball is never in the previous
release), so it rewrites a throwaway copy of the recipe: the `kilonova` part
becomes a dump of the local tarball, checksummed with its own hash. Every
other part, the apps, the plugs and the platforms stay as committed.

    tools/ci/snap-local-tarball.py snap/snapcraft.yaml <tarball relative to the project>
"""
import hashlib
import sys

import yaml

path, tarball = sys.argv[1:3]

with open(path) as f:
    recipe = yaml.safe_load(f)

with open(tarball, "rb") as f:
    digest = hashlib.sha256(f.read()).hexdigest()

recipe["parts"]["kilonova"] = {
    "plugin": "dump",
    "source": tarball,
    "source-checksum": f"sha256/{digest}",
}

with open(path, "w") as f:
    yaml.safe_dump(recipe, f, sort_keys=False, width=1000)
