# -*- python-indent-offset: 2; -*-
# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

"""Access Google Storage using gcloud internal undocumented API.

For convenience, aliases for all gRPC message types used in this module
are exposed from it:

  Bucket
  Object
  StorageObjectsListRequest

so that you can refer to storage.Bucket instead of rather unwieldy
googlecloudsdk.third_party.apis.storage.v1.storage_v1_messages.Bucket.
"""

from typing import Sequence as _Sequence
import apitools.base.py.list_pager as _pager
import googlecloudsdk.api_lib.storage.storage_api as _gsapi
import googlecloudsdk.third_party.apis.storage.v1.storage_v1_messages as _gsmv1

# Expose aliases to types consumed or returned in this module.
# pylint: disable=unused-import
from googlecloudsdk.third_party.apis.storage.v1.storage_v1_messages import(
  Object, Bucket, StorageObjectsListRequest)

from . import project as _project

def ListBuckets(project_id: str = None) -> _Sequence[Bucket]:
  # Documentation lifted from the gRPC message docstrings, abridged.
  """List buckets in a project.

  Returns a sequence of Bucket message objects for each bucket, with the
  following fields:

    acl: Access controls on the bucket.
    billing: The bucket's billing configuration.
    cors: The bucket's Cross-Origin Resource Sharing (CORS) configuration.
    defaultEventBasedHold: The default value for event-based hold on newly
        created objects in this bucket.
    defaultObjectAcl: Default access controls to apply to new objects when
        no ACL is provided.
    encryption: Encryption configuration for a bucket.
    etag: HTTP 1.1 Entity tag for the bucket.
    iamConfiguration: The bucket's IAM configuration.
    id: The ID of the bucket' for a buckets, same as name.
    kind: The kind of item this is. For buckets, this is always storage#bucket.
    labels: User-provided labels, in key/value pairs.
    lifecycle: The bucket's lifecycle configuration.
    location: The location of the bucket. Object data for objects in the
        bucket resides in physical storage within this region.
    locationType: The type of the bucket location.
    logging: The bucket's logging configuration, which defines the destination
        bucket and optional name prefix for the current bucket's logs.
    metageneration: The metadata generation of this bucket.
    name: The name of the bucket.
    owner: The owner of the bucket.
    projectNumber: The project number of the project the bucket belongs to.
    retentionPolicy: The bucket's retention policy.
    selfLink: The URI of this bucket.
    storageClass: The bucket's default storage class, used whenever no
        storageClass is specified for a newly-created object.
    timeCreated: The creation time of the bucket in RFC 3339 format.
    updated: The modification time of the bucket in RFC 3339 format.
    versioning: The bucket's versioning configuration.
    website: The bucket's website configuration, controlling how the service
        behaves when accessing bucket contents as a web site.
  """
  if not project_id:
    project_id = _project.GetCurrent()

  gsclient = _gsapi.StorageClient()
  return gsclient.ListBuckets(project_id)


def ListObjects(bucket: str, **kwargs) -> _Sequence[Object]:
  # Documentation lifted from the gRPC message docstrings, abridged.
  # Here the StorageClient API is not adequate, as it does not return non-
  # current versions in a versioned bucket, and we do use versions. We use
  # the client for authentication, but then use the gRPC request and
  # response messages directly.
  """List objects in a bucket.

  Arguments are used to construct the StorageObjectsListRequest message,
  which is then executed by the gcloud-authenticated client. They are
  passed via kwargs (except 'bucket', which is required):

    bucket: Name of the bucket in which to look for objects.
    delimiter: Returns results in a directory-like mode. items will contain
       only objects whose names, aside from the prefix, do not contain
       delimiter. Objects whose names, aside from the prefix, contain delimiter
       will have their name, truncated after the delimiter, returned in
       prefixes. Duplicate prefixes are omitted.
    includeTrailingDelimiter: If true, objects that end in exactly one
        instance of delimiter will have their metadata included in items in
        addition to prefixes.
    maxResults: Maximum number of items plus prefixes to return in a single
        page of responses. As duplicate prefixes are omitted, fewer total
        results may be returned than requested. The service will use this
        parameter or 1,000 items, whichever is smaller.
    pageToken: A previously-returned page token representing part of the
        larger set of results to view.
    prefix: Filter results to objects whose names begin with this prefix.
    projection: Set of properties to return. Defaults to noAcl.
    provisionalUserProject: The project to be billed for this request if the
        target bucket is requester-pays bucket.
    userProject: The project to be billed for this request. Required for
        Requester Pays buckets.
    versions: If true, lists all versions of an object as distinct results.
        The default is false. For more information, see Object Versioning.

  Return value is a sequence of the gRPC messages of type Object, representing
  storage objects matching the query, each with the following fields:

    acl: Access controls on the object.
    bucket: The name of the bucket containing this object.
    cacheControl: Cache-Control directive for the object data. If omitted, and
        the object is accessible to all anonymous users, the default will be
        public, max-age=3600.
    componentCount: Number of underlying components that make up this object.
        Components are accumulated by compose operations.
    contentDisposition: Content-Disposition of the object data.
    contentEncoding: Content-Encoding of the object data.
    contentLanguage: Content-Language of the object data.
    contentType: Content-Type of the object data. If an object is stored
        without a Content-Type, it is served as application/octet-stream.
    crc32c: CRC32c checksum, as described in RFC 4960, Appendix B; encoded
        using base64 in big-endian byte order.
    customerEncryption: Metadata of customer-supplied encryption key, if the
        object is encrypted by such a key.
    etag: HTTP 1.1 Entity tag for the object.
    eventBasedHold: Whether an object is under event-based hold.
    generation: The content generation of this object. Used for object
        versioning.
    id: The ID of the object, including the bucket name, object name, and
        generation number.
    kind: The kind of item this is. For objects, this is always storage#object.
    kmsKeyName: Cloud KMS Key used to encrypt this object, if the object is
        encrypted by such a key.
    md5Hash: MD5 hash of the data; encoded using base64.
    mediaLink: Media download link.
    metadata: User-provided metadata, in key/value pairs.
    metageneration: The version of the metadata for this object at this
        generation. Used for preconditions and for detecting changes in
        metadata. A metageneration number is only meaningful in the context of a
        particular generation of a particular object.
    name: The name of the object.
    owner: The owner of the object.
    retentionExpirationTime: A server-determined value that specifies the
        earliest time that the object's retention period expires. This value is
        in RFC 3339 format.
    selfLink: The link to this object.
    size: Content-Length of the data in bytes.
    storageClass: Storage class of the object.
    temporaryHold: Whether an object is under temporary hold.
    timeCreated: The creation time of the object in RFC 3339 format.
    timeDeleted: The deletion time of the object in RFC 3339 format. Will be
        returned if and only if this version of the object has been deleted.
    timeStorageClassUpdated: The time at which the object's storage class was
        last changed. When the object is initially created, it will be set to
        timeCreated.
    updated: The modification time of the object metadata in RFC 3339 format.
  """
  request = _gsmv1.StorageObjectsListRequest(bucket=bucket, **kwargs)
  gsrpcclient = _gsapi.StorageClient().client
  return _pager.YieldFromList(gsrpcclient.objects, request)
