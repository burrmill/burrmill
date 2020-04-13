#!/usr/bin/env python3
# -*- python-indent-offset: 2; -*-
# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

# This is a cloud function to delete all untagged images from project's
# container image registry. We address images only by tag, and any untagged
# image would be sitting in the repository, consuming extra space.
#
# The function is invoked by a PubSub topic triggered by the Cloud Build. We do
# the trimming only on successful completion of a build which has pushed any
# image. We still look at all images, just in case a previous run has failed.
#
# This machinery is well below the GCP free tier limit, and cost you nothing.
# The only caveat is to deploy it in the same multiregion (roughly, continent)
# as the registry itself, to avoid cross-continental API calls; it would still
# cost next to nothing, but less reliable and makes no sense. Cloud Functions
# are regional, but not available in any region. Use 'gcloud functions regions
# list' to get a current list. The following mapping is recommended based on the
# current (2019) availability:
#
#   us   => us-central1
#   eu   => europe-west1
#   asia => asia-northeast1
#
# We do not use higher-level libraries here, since they do not exist for either
# the Docker registry API (which Google just redirects to Docker), nor for the
# runtimeconfig API, which is in beta and does not have a client support
# (yet?). Everything is handled using REST APIs with the requests library.

import base64, json, requests, sys

# Globals.
g_sess = requests.Session()

# Report a fatal error in context associated with an HTTP response.
def _failed(resp, reason):
  req = resp.request
  raise RuntimeError(f"A {req.method} request to {req.url} failed: "
                     f"{reason}. Response was: {vars(resp)}")


# Die if an HTTP request ended unsuccessfully. There is no library to handle
# registries, so we use raw REST/HTTP. It will probably fail once in a while,
# since we do not do a proper GCP OAuth token refresh. Image deletion may return
# with a 202 Accepted code, and is performed asynchronously. Of other requests,
# we expect the 200 return code.
def _check_2xx(resp, only200 = True):
  status = resp.status_code
  if ((only200 and status != 200) or
      (not only200 and status // 100 != 2)):
    _failed(resp, f"HTTP status {status}")


# This can be called only in GCP environment to retrieve runtime metadata.
def _get_metadata(meta):
  resp = g_sess.get(f"http://169.254.169.254/computeMetadata/v1/{meta}",
                    headers={'Metadata-Flavor':'Google'})
  _check_2xx(resp)
  if not resp.text:
    _failed(resp, f"Unable to retrieve metadatum {meta}")
  return resp.text


# Get the function's service account OAuth token. Since we run rarely, it is
# likely to be fresh, so we never try to refresh it on a 401 for simplicity.
# This method may only work in the GCP environment.
def _get_gctoken():
  tok = json.loads(_get_metadata('instance/service-accounts/default/token'))
  return f"{tok['token_type']} {tok['access_token']}"


# Extract project codename from metadata. This can be called only on GCP.
def _get_project():
  return _get_metadata('project/project-id')


# Parse out gs_location from the project global config. The variable looks like
# "gs_location=us gs_scratch=gs://foo gs_software=gs://bar"; although intended
# for shell, the values are never quoted, so that simple splitting on spaces
# and then on equal signs will do the job.
def _get_location(project, gctoken):
  # Runtime config path to burrmill/globals variable.
  vurl = (f"https://runtimeconfig.googleapis.com/v1beta1/projects/"
          f"{project}/configs/burrmill/variables/globals")

  # Response is a JSON string like { "text": "gs_location=us gs_...", ...}.
  resp = g_sess.get(vurl, headers = {'Authorization': gctoken})
  _check_2xx(resp)

  for v in json.loads(resp.text)['text'].split():
    ix = v.find('=')
    if ix >= 0 and v[:ix] == 'gs_location':
      return v[ix+1:]

  raise RuntimeError(f"Project '{project}' is missing the global "
                     f"configuration value 'gs_location'")


# Walk all repositories in registry. The registry has its own authentication,
# which is performed by a separate endpoint. Another notable architecture detail
# is that each image requires its own separate authentication with a 'push'
# scope; the whole registry allows only the 'pull' scope to enumerate images.
# This can be called locally for debugging, as it does not try to access
# metadata server (or even GCP API libraries) by itself. The GCP registry
# implements the Docker API v2: https://docs.docker.com/registry/spec/api/.
def _delete_untagged_images(project, location, gctoken):
  service=f"{location}.gcr.io"        # Registry service.
  gcauth={'Authorization': gctoken}   # GCP auth headers.

  # Trade a GCP token for the registry API token for given library and scope.
  # Return a dict with the Authorization header for the registry.
  def _authorize(library='', scope='pull'):
    if library: library = '/' + library
    resp = g_sess.get((f"https://{service}/v2/token?scope=repository:"
                       f"{project}{library}:{scope}&service={service}"),
                      headers=gcauth)
    _check_2xx(resp)
    repo_token='Bearer ' + json.loads(resp.text)['token'];
    return {'Authorization': repo_token}

  # GCP allows only the 'pull', readonly scope at the top level.
  resp = g_sess.get(f'https://{service}/v2/{project}/tags/list',
                    headers=_authorize())
  _check_2xx(resp)

  images=json.loads(resp.text)['child']
  delcount = 0
  for img in images:
    # Authorize with the 'push', R/W scope, since we are deleting images.
    auth = _authorize(img, 'push')
    resp = g_sess.get(f'https://{service}/v2/{project}/{img}/tags/list',
                      headers=auth)
    _check_2xx(resp)
    versions=json.loads(resp.text).get('manifest')
    if not versions:
      _failed(resp, "No manifest was returned")

    for sha, man in iter(versions.items()):
      if man['tag'] == []:  # Better be explicit than sorry.
        print(f"Deleting untagged image {project}/{img}@{sha}")
        resp = g_sess.delete(
          f'https://{service}/v2/{project}/{img}/manifests/{sha}',
          headers=auth)
        _check_2xx(resp, only200 = False)  # Expect 200 or 202 on success.
        delcount += 1

  if not delcount:
    print(f"No untagged images were found in {service}/{project}/{images}")


# This is used if we have no idea where the message came from. Obtain all IDs in
# a different way (using the metadata and resource manager APIs).
def _delete_untagged_images_nocontext():
  project = _get_project()  # E.g., 'beloved-cluster-rfd4z'
  gctoken = _get_gctoken()  # E.g., 'Bearer y29.abcde.....'
  location = _get_location(project, gctoken)  # E.g., 'us'.
  _delete_untagged_images(project, location, gctoken)
  return True


# Cloud Function entry point.
def delete_untagged_images(evt, ctx):
  # Check if message is from cloud build; do it differently if not. Useful to
  # force cleanup by simply calling the function with an empty message.
  attrs = evt.get('attributes')
  if not (attrs and 'buildId' in attrs and 'status' in attrs and 'data' in evt):
    return _delete_untagged_images_nocontext()

  # Run cleanup only after a successful build.
  if attrs['status'] != 'SUCCESS':
    return True

  # Decode Cloud Build message, look for images. Do not run if the build has not
  # pushed any images.
  data = json.loads(base64.b64decode(evt['data']).decode('utf-8'))
  images = data.get('images')
  if not images:
    print(f"No new images pushed in build {attrs['buildId']}, skipping cleanup")
    return True

  parts = str.split(images[0], '/')  # ['us.gcr.io', 'projname', 'cxx']
  project = parts[1]
  parts = str.split(parts[0], '.')   # ['us', 'gcr', 'io']
  location = parts[0]
  if location not in ['us','eu','asia']:
    raise RuntimeError(f"The target of the image {images[0]} is not pointing " +
                       f"to one of the known locations ['us','eu','asia']. " +
                       f"Aborting. BuildId was '{attrs['buildId']}'")

  gctoken = _get_gctoken()

  _delete_untagged_images(project, location, gctoken)
  return True


# For local debugging.
if __name__ == '__main__':
  if len(sys.argv) != 4:
    exit(f"Usage: {sys.argv[0]} <project> <location> <authtoken>")
  # If no token type, assume 'Bearer'.
  token = sys.argv[3]
  if ' ' not in token: token = 'Bearer ' + token
  _delete_untagged_images(sys.argv[1], sys.argv[2], token)
