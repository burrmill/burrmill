# -*- python-indent-offset: 2; -*-
# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

"Undocumented gcloud credential store access"

import googlecloudsdk.core.credentials.store as _credstore  # Undocumented.

# Expose aliases to types consumed or returned in this module.
# pylint: disable=unused-import
from google.oauth2.credentials import Credentials  # Documented.

def GetFull() -> Credentials:
  """Get documented API credentials from undocumented gcloud store.

  Load the current user's credentials and construct a supported
  google.oauth2.credentials.Credentials instance from it. The token
  has full user's scopes, and may be fresh for some time.

  Note that on a GCE instance, the credentials and scopes are those
  of the instance's service account, not the logged-on user.
  """
  ucr = _credstore.Load()
  gcr = Credentials(ucr.access_token, refresh_token=ucr.refresh_token,
                    id_token=ucr.id_token, token_uri=ucr.token_uri,
                    client_id=ucr.client_id, client_secret=ucr.client_secret,
                    scopes=list(ucr.scopes))
  gcr.expiry = ucr.token_expiry
  return gcr


def GetScoped(scopes=None) -> Credentials:
  """Get documented API credentials from undocumented gcloud store.

  scopes: optional list of scopes. By default, no scopes are set.

  Load the current user's credentials and construct a supported
  google.oauth2.credentials.Credentials instance from it. The
  object has no token and no scopes by default, and must be
  refreshed before use.

  Note that on a GCE instance the credentials and scopes are those
  of the instance's service account, not the logged-on user.
  """
  ucr = _credstore.Load()
  scopes = list(scopes) if scopes else None
  return Credentials.from_authorized_user_info(vars(ucr), scopes=scopes)


def GetFreshToken() -> str:
  "Get a fresh Bearer access token, good for about 60 minutes."
  ucr = _credstore.Load()
  _credstore.Refresh(ucr)
  return ucr.access_token
