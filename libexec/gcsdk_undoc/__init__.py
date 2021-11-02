# -*- python-indent-offset: 2; -*-
# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

"""Access gcloud internal undocumented API.

This is not how we should access APIs, but this seems the only way to do just
anything from Python command-line utilities without having the user to go
through unnecessary additional authentication steps. And, while gcloud output
is deterministic, configurble and parseable, gsutil is far worse in that
regard, so choose your poison.
"""

# This is embarrasing. Google should un-undocument this API.
# https://github.com/GoogleCloudPlatform/docker-credential-gcr/blob/e84196148/credhelper/helper.go#L212-L215

# Use functions to scope away imported names and local variables, to avoid
# polluting our module namespace.

# Locate SDK lib and lib/third_party directories and prepend them to the
# sys.path. 'gcloud info' shows the lib/third_party goes before lib/.
def _ExtendSyspath():
  from shutil import which
  import os
  import sys

  path = which('gcloud')
  assert path
  path = os.path.realpath(os.path.join(path, '..', '..', 'lib'))
  assert os.path.exists(path)
  sys.path.insert(0, path)
  path = os.path.join(path, 'third_party')
  assert os.path.exists(path)
  sys.path.insert(0, path)

_ExtendSyspath()
del _ExtendSyspath

# This is What They do Themselves: see <sdk>/lib/googlecloudsdk/gcloud_main.py.
# This is how authentication in devshell or GCE "magically" works.
#
# DevShell can be detected by checking if DEVSHELL_CLIENT_PORT is set in the
# environment (again, Their Own approach), GCE is trickier tho. I often cat
# /sys/class/dmi/id/chassis_vendor' to see if the vendor string is 'Google',
# But for now, just register these modules blindly. If it breaks, I'll fix it.
def _RegisterGcsdkCredProviders():
  from googlecloudsdk.core.credentials import store
  try:
    # DevShellCredentialProvider() has been removed, no longer needed?
    store.DevShellCredentialProvider().Register()
  except AttributeError:
    pass
  store.GceCredentialProvider().Register()


_RegisterGcsdkCredProviders()
del _RegisterGcsdkCredProviders

# These would fail before we muck with the sys.path.
# pylint: disable=wrong-import-position
from . import credentials, project, storage

def ApToDict(aps) -> dict:
  """Convert list of AdditionalProperty messages to dict.

  aps.additionalProperties is an iterable protorpclite.messages.FieldList
  type of some messages (usually of type AdditionalProperties), which
  have a 'key' and a 'value' attributes. Returned is the dict of these
  key-value pairs.

  If aps tests False, an empty dict() is returned.
  """
  return {x.key:x.value for x in aps.additionalProperties} if aps else {}
