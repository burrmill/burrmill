# -*- python-indent-offset: 2; -*-
# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

"Access projects using gcloud internal undocumented API."

from types import SimpleNamespace as _Ducky

import googlecloudsdk.core.properties as _properties
import googlecloudsdk.api_lib.cloudresourcemanager.projects_api as _projapi

# Expose aliases to types consumed or returned in this module.
# pylint: disable=unused-import
from googlecloudsdk.third_party.apis.\
       cloudresourcemanager.v1.cloudresourcemanager_v1_messages import Project

def GetCurrent() -> str:
  "Return the string project ID from the current local configuration."
  return _properties.VALUES.core.project.Get()

def Describe(project_id: str = None) -> Project:
  """
  Return the protobuf message describing the project.

  project_id: the string ID of the project. If omitted, the current
              configured project is used.

  A helper function ap_to_dict is provided, which also handles a case
  of a missing collection (and returns an empty dict in this case):

     ap_to_dict(proj.labels) -> dict
  """
  if not project_id:
    project_id = GetCurrent()
  # Use the SimpleNamespace ducky instead of the "official" ProjectReference
  # instance, because 'projectId' is all the API wants.
  return _projapi.Get(_Ducky(projectId=project_id))
