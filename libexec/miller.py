#!/usr/bin/env python3
# -*- python-indent-offset: 2; -*-
# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

# This is a low-level utility that loads and analyses Millfiles, checks which
# aerifacts are available and which must be build, and also collects artifacts
# for building the CNS disk. It outputs directives for invoking scripts to
# stdout. The reason is we have to resort to using some undocumented API of the
# Cloud SDK to authenticate transparently to the user, and it's desirable to
# minimize the use of these APIs. Cloud Build, for one, is invoked by the
# caller, using 'gcloud builds', presumably.
#
# Besides the non-typical indent of 2, the code uses the identifier 'my' where
# 'self' is more usual. Also, there is no space between variable and its type
# annotation ('i:int', not 'i :int'). Line length better not exceed 80, but I'm
# not too OC about this. Also, single-line 'if x: ...' or def is totally fine.
# dedent() is never used; literals touching the left margin are A-OK. Please
# stick with these unconventional conventions if sending a PR.
#
# How come this limited scope "helper script" to process a 5-10 line Millfile
# grew up to nearly 900 lines of code in length, I have no idea.

import argparse as ap
import json
import os.path
import pprint as pp
import re
import sys

from dataclasses import dataclass, field
from fileinput import FileInput
from functools import reduce
from itertools import chain, filterfalse
from os import environ
from typing import (Callable,
                    List,
                    Mapping as Map,
                    NoReturn,
                    Optional as Opt,
                    Set,
                    Iterable as Seq,
                    Tuple)

import requests  # Not in stdlib, but ubiquitous. Cloud Shell has it.

from gcsdk_undoc import *  # Our package in libexec/.

#==============================================================================#
# Global globals (some sections define more).
#==============================================================================#

g_session = None         # Session library's session.
g_gtoken:str = None      # Bearer token, good for 60 minutes.
g_debug:int = 0          # This is set early in args_parse.
g_project:str = None     # Project string ID
gs_location:str = None   # Multiregion, e.g. 'us' from global config.
gs_software:str = None   # Name of the Software bucket, also from config.

ME = os.path.basename(sys.argv[0])

INFO = 'INFO'
WARNING = 'WARNING'
FATAL = 'FATAL'
SGR0 = ''

# Try to spice it up with colors, if terminfo is available and functioning.
try:
  import curses
  curses.setupterm()
  sgr0 = curses.tigetstr('sgr0')
  setaf = curses.tigetstr('setaf')
  if sgr0 and setaf:
    r, y, w = (curses.tparm(setaf, i).decode('ascii') for i in (9,11,15))
    SGR0 = sgr0.decode('ascii')
    INFO = w + INFO + SGR0
    WARNING = y + WARNING + w
    FATAL = r + FATAL + w
  del setaf, sgr0, r, y, w
except Exception:
  pass

#==============================================================================#
# Stderr message reporting functions.
#==============================================================================#

def _say(*args) -> None:
  print(ME, ':', *args, SGR0, sep='', file=sys.stderr)

def debug(level:int, *args) -> None:
  if g_debug >= level: _say(f"DEBUG({level}):", *args)

def info(*args) -> None:
  _say(INFO, ':', *args)

def warn(*args) -> None:
  _say(WARNING, ':', *args)

def fatal(*args) -> NoReturn:
  _say(FATAL, ':', *args)
  sys.exit(1)

#==============================================================================#
# Misc small data classes and type signatures.
#==============================================================================#

# Any exception we raise, we catch.
class _Error(Exception): pass


@dataclass(frozen=True)
class FileLine():
  "File and line number from which a directive was loaded."
  filename: str; lineno: int
  def __str__(my):
    return f"{my.filename}:{my.lineno}"


# Raise that when there is a related Millfile location; for
# everything else, just call fatal().
@dataclass(frozen=True)
class ParseError(_Error):
  "A parse error with filename, line number and a message"
  fileline: FileLine
  message: str
  def __str__(my):
    return f"{my.fileline}: ParseError: {my.message}"


# Helper to construct and raise a ParseError.
def parse_error(fnl:FileLine, *args) -> NoReturn:
  raise ParseError(fnl, ' '.join([str(s) for s in args]))


# Pre-syntactic file record, a line with possible continuations assembled.
FileRecord = Tuple[FileLine,Seq[str]]

# Syntactic tokenized record, with the colon-separated fields parsed.
TokenRecord = Tuple[FileLine,Tuple[Seq[str],Set[str],Map[str,str]]]

#==============================================================================#
# Argument parsing.
#==============================================================================#

# Sanitize data bucket name by stripping 'gs://' at the start and '/' at end.
# Return sane bucket name (not empty, no '/' in it), or None on error.
def _sanitize_gsbucket_url(buck:str) -> str:
  if not buck: return None
  if buck.startswith('gs://'): buck = buck[5:]
  if buck.endswith('/'): buck = buck[:-1]
  if not buck or '/' in buck: return None
  return buck

# Scope argparser under the carpet, we need it once. The only side effect is
# that this function sets the g_debug variable as soon as arguments are parsed,
# and starts logging debug info even before it returns.
def parse_args() -> ap.Namespace:
  global g_debug

  def default_millfiles() -> Seq[str]:
    # We're in x/libexec for some x. The main Millfile is in x/lib/build, and
    # the user's optional overrides file is in x/etc/build.
    x = os.path.realpath(__file__)
    x = os.path.dirname(x)
    x = os.path.dirname(x)

    mainfile = os.path.join(x, 'lib', 'build', 'Millfile')
    if not os.path.exists(mainfile):
      fatal(f"Default build file {mainfile} was not found")
    debug(1, f"Using standard build file {mainfile}")

    userfile = os.path.join(x, 'etc', 'build', 'Millfile')
    if os.path.exists(userfile):
      debug(1, f"Using user's augmentation file {userfile}")
      return [mainfile, userfile]
    else:
      return [mainfile]

  description = \
"""Examine the state of all build targets and indicate those that must be.

TL;DR: This is a low-level helper for the build scripts. You'll hardly use it.

With no arguments, examine all targets defined by the lib/build/Millfile, and,
if present, overrides added by the user in etc/Millfile, and rebuild those that
do not match the version or absent.

Read comments in the default Millfile to understand its structure.

To build custom targets, add them to etc/Millfile. For one-off builds, you can
add another file to the default chain, or use a completely custom files and
ignore these default locations with the --omit-std option. This is hardly used
outside of testing, however.

Millfiles declare the desired state of the components on the common shared
software disk of the system. The --targets option provides the list of seed
targets to build (the list is expanded with their dependencies, recursively
until closure. Absent --targets, all target are examined. The --force option
forces the rebuild of a target, even if it otherwise would not be built. This
applies only to the target itself, not its dependencies. When both --targets and
--force are provided, targets from --force are added to the --targets set (this
is a normal behavior, considering that absense of the --targets option means
"the set of all targets"). As a practical use case, --force=cxx is a good option
to rebild the unversioned cxx builder without rebuilding its dependencies. The
special case of --force=* rebuilds everything.

The utility stdout may be used to quickly assess discrepancies between the
current and desired states of the target disk, but this is used by other
machinery, external to this script.
"""
  p = ap.ArgumentParser(description=description,
                        formatter_class=ap.RawDescriptionHelpFormatter)
  a = p.add_argument
  a('files', metavar='FILE', nargs='*',
    help="Millfiles to add to/replace (-m) the default chain.")
  a('--debug', '-d', metavar='N', type=int, default=0,
    help="Print debug messages; the larger N, the merrier.")
  a('--omit-std', '-m', action='store_true',
    help="Omit standard Millfile chain.")
  a('--force', '-f', type=str, metavar='TARGET[,TARGET...] | *',
    help="Force rebuild of these targets, even if current. * to rebuild all.")
  a('--targets', '-t', type=str, metavar='TARGET[,TARGET...]',
    help=("Build only these targets. Default is to consider all targets."))
  a('--gather', action='store_true', help="'gather', n. Opposite of 'build'.")
  # Optional, but save on remote API calls if supplied *correctly*.
  a('--gs-location', metavar='LOC', type=str, help='Optional')
  a('--gs-software', metavar='GSPATH', type=str, help='Optional')
  a('--project', metavar='NAME', type=str, help='Optional')

  o = p.parse_args()
  g_debug = max(0, o.debug)

  if o.omit_std and not o.files:
    p.error('No files to process; some are required with -m/--omit-std.')
  if not o.omit_std:
    o.files = default_millfiles() + o.files
  debug(1, f"Command line: files={o.files}")

  o.rebuild_all = o.force == '*'
  if o.targets == '*':
    o.targets = None  # Allow --targets=*, too.
  if o.rebuild_all and o.targets:
    p.error(f"'--targets={o.targets}' makes no sense with '--force=*'")
  if o.rebuild_all:
    warn('Forcibly rebuilding all targets')
    o.targets = o.force = None
  if o.force:
    o.force = frozenset(o.force.split(','))
  if o.targets:
    o.targets = frozenset((*o.targets.split(','), *(o.force or ())))

  # Calling scripts sometimes export these; this saves a remote call.
  if not o.gs_location: o.gs_location = environ.get('gs_location')
  if not o.gs_software: o.gs_software = environ.get('gs_software')

  if o.gs_software:
    gs = _sanitize_gsbucket_url(o.gs_software)
    if not gs:
      p.error(f"--gs-software is passed invalid value '{o.gs_software}'")
    o.gs_software = gs

  debug(2, (f"Command line: targets={o.targets}, force={o.force}, "
            f"rebuild_all={o.rebuild_all}, project={o.project}, "
            f"gs_location={o.gs_location}, gs_software={o.gs_software}"))
  return o

#==============================================================================#
# Reading and tokenizing Millfiles.
#==============================================================================#

# This can accept a mock FileInput for unit testing. Not that I'm writing any.
def read_files(inp:FileInput) -> Seq[FileRecord]:
  with inp:
    f = n = None; acc = []
    for line in inp:
      if inp.isfirstline():
        debug(1, f"Loading file {inp.filename()}")
        if acc:
          yield (FileLine(f, n), acc)
          acc = []
        f, n = inp.filename(), inp.filelineno()
      i = line.find('#')
      if i >= 0: line = line[:i]
      line = line.rstrip()
      if not line: continue
      if line[0].isspace():
        if acc:
          acc.append(line)
        else:
          parse_error((inp.filename(), inp.filelineno()),
                'Non-continuation (first in file) line starts with whitespace')
      else:
        if acc:
          yield (FileLine(f, n), acc)
        acc = [line]
        n = inp.filelineno()
    if acc:
      yield (FileLine(f, n), acc)


# This uses constructs a real FileInput for read_files.
def _read_real_files(files: Seq[str]):
  return read_files(FileInput(files))

# Raise a ParseError if v is invalid variable name.
def validate_buildvar(fnl:FileLine, v:str):
  if not re.fullmatch(r'(?:_[0-9A-Z]+)+', v):
    parse_error(fnl, (f"Malformed variable '{v}'. All user-defined variables "
                      f"must begin with the underscore '_', contain only "
                      f"capital letters and digits, not end with an underscore "
                      f"and not contain two underscores in a row."))
  if v.startswith('_GS_'):
    parse_error(fnl, (f"Malformed variable '{v}'."
                      f"The prefix '_GS_' is reserved by BurrMill."))

# Parse a variable assignment sequence into a dict.
def parse_var_map(fnl:FileLine, s:Seq[str]) -> Map[str,str]:
  res = dict()
  for a in s:
    k, v, *__ = a.split('=', maxsplit=2) + [None]
    if not k or '=' not in a:
      parse_error(fnl, 'Malformed assignment', a)
    validate_buildvar(fnl, k)
    if k in res:
      parse_error(fnl, f"in '{a}': variable '{k}' assigned twice on the line")
    res[k] = v
  return res

# Validate a simple directive for minimum number of tokens and absence
# of additional colon-separated sections.
def validate_nocolon(rec:TokenRecord, mintok) -> None:
  fnl, (body, two, three) = rec
  badcnt = len(body) < mintok
  badcol = two or three
  if badcol or badcnt:
    err = [f"Directive '{body[0]}'"]
    if badcnt: err.append(f"requires at least {mintok-1} arguments")
    if badcnt and badcol: err.append('and')
    if badcol: err.append('does not accept colon-separated fields')
    parse_error(fnl, *err)


# Parse one logical line produced by read_lines. This does not deal with its
# semantics yet. Remember that the line consist of up to 3 logical fields
# separated by the ':'. We require a space after the ':', just to avoid
# awkwardness like 'tar foo:_X=http://bar', in case the user forget the second
# colon and we add '_X=http' as a dependency; and to prevent splitting e.g.
# 'ver kaldi feef00faa _KALDI_REPO=git://myownrepo.git' on 'git://'. This
# function shuffles all parts except for variable overrides in the 'ver' clause,
# which remain monolithic tokens, as they are not syntactically distinct.
def tokenize_line(rec: FileRecord) -> TokenRecord:
  fnl, lines = rec
  line = ''.join(lines)  # Continuation lines are left-padded already.
  # NB: re.split will include capturing groups into the splits (like Perl but
  # unlike .NET or C++ re2), so we must use non-capturing grouping here. After
  # splitting on the ':', split each token on runs of spaces.
  parts = [s.split() for s in re.split(r':(?:\s+|$)', line, maxsplit=3)]
  # There are up to 3 parts, and they are treated differently:
  #   1: Always a sequence of tokens, e.g. [tar kaldi abcde1234 _KALDI_VER]
  #   2: An unordered set of dependencies, e.g. {cxx cuda mkl}.
  #   3: A mapping of unique variables to values e.g. {_KALDI_REPO: git://etc}
  # First token in line determines the semantics, but we'll deal with it later.
  # e.g. [ver kaldi 1234abcde _KALDI_REPO=git://foo/kaldi.git] stays as is for
  # now, as we still do syntax only, and do not distinguish tokens.
  p1, p2, p3, *__ = parts + [[]]*2  # Don't blow up on a shorter list.
  return (fnl, (p1, frozenset(p2), parse_var_map(fnl, p3)))

# Parse one logical line produced by read_lines. This does not deal with its
# semantics yet.
def _tokenize(s: Seq[FileRecord]) -> Seq[TokenRecord]:
  yield from map(tokenize_line, s)

#==============================================================================#
# Interacting with GCS API to locate target artifacts.
#==============================================================================#

# Report a fatal error with a detailed message if HTTP response was not 200.
def _check_200(resp):
  if resp.status_code != 200:
    req = resp.request
    fatal(f"A {req.method} request to {req.url} failed with HTTP error "
          f"{resp.status_code}. Full response was: {vars(resp)}")


# Requests library and bearer token lazy intialization.
def _ensure_requests_session_and_gtoken():
  global g_session, g_gtoken
  if not g_session:
    g_session = requests.Session()
  if not g_gtoken:
    g_gtoken = 'Bearer ' + credentials.GetFreshToken()

# Project config lazy intialization.
#
# If known to the invoker, better passed via command line or the environment to
# save on a couple API call roundtrips.
def _ensure_gs_config():
  global g_project, gs_location, gs_software
  if not g_project:
    g_project = project.GetCurrent()
    if not g_project:
      fatal('Cannot determine active project. Use "gcloud config list" to '
            'check your local configuration. If using the Cloud Shell, select '
            'one in the drop-down list above terminal window.')
    debug(1, f"Current project set to '{g_project}'")

  # Do nothign if already initialized.
  if gs_location and gs_software: return

  _ensure_requests_session_and_gtoken()

  # Obtain the global configuration using the runtimeconfig API.
  # Nearly a clone from lib/functions/delete_untagged_images/main.py
  vurl = (f"https://runtimeconfig.googleapis.com/v1beta1/projects/"
          f"{g_project}/configs/burrmill/variables/globals")

  # Response is a JSON string like { "text": "gs_location=us gs_...", ...}.
  resp = g_session.get(vurl, headers = {'Authorization': g_gtoken})
  _check_200(resp)

  debug(1, f"Got project config '{resp.text}'")
  for v in json.loads(resp.text)['text'].split():
    debug(2, f"Parsing a config assigment '{v}'")
    ix = v.find('=')
    if ix < 0: continue  # Weird, but what can we do.
    if v[:ix] == 'gs_location':
      gs_location = v[ix+1:]
    elif v[:ix] == 'gs_software':
      gs_software = v[ix+1:]

  if not gs_location:
    fatal(f"Project '{g_project}' has not configured the 'gs_location'")
  if not gs_software:
    fatal(f"Project '{g_project}' has not configured the 'gs_software'")

  # As we accept optonal heads and tails [gs://]bucket_name[/], strip them.
  v = _sanitize_gsbucket_url(gs_software)
  if not v: fatal(f"Project '{g_project}' has invalid config value "
                  f"gs_software={gs_sofware}")
  gs_software = v

#----- GS service globals, for tarballs. ---------------------------------------

# 4-tuples (version * current * name * generation) list.
# - version is set to '' if not set, otherwise sort fails.
# - current: 0 if deleted, 1 if current.
# - filename w/o the 'tarballs/' prefix
# - generation number.
g_tarball_cache = None

TARBALLS_DIR = 'tarballs/'
GSSW_WARN_THRESHOLD = 150
GSSW_ERROR_THRESHOLD = 1000

def _ensure_tarball_cache():
  global g_tarball_cache
  if g_tarball_cache is not None:  # Can be a genuinely empty list.
    return

  g_tarball_cache = []
  for o in storage.ListObjects(bucket=gs_software,
                               prefix=TARBALLS_DIR,
                               delimiter='/',  # Do not search "subdirectories".
                               versions=True): # Show all versions though.
    if not o.name.endswith('.tar.gz'):
      continue
    # We look for objects, superseded or not, with our Version metadatum, and
    # also for "courtesy" matches of the form NAME-VERSION.tar.gz, but only if
    # they have no Version set (this way lays insanity if the versions in the
    # name and metadata do not match), and only if they are current (i.e., the
    # user has deleted such a file, and it's "gone" if non-current). Thus, we
    # ignore non-current objects without the Version metadatum.
    #
    # To make a single pass over the array and select the first found match as
    # satisfying the search criterion, sort current files with the version, then
    # non-current with the version, and files without the version meta the last.
    # To avoid mucking with Python's date comparisons, which are non-trivial,
    # simply use an integer currency status, 1 for current and 0 for non-current
    # (objects which have the delete time set). The reverse sort on (version *
    # currency) will do, the non-versioned objects go to the end of the list.
    #
    # The list is not normally long, 20-40 objects is a practically expected
    # size. Give a warning if suspiciously large, fail fatally if crazy large.
    # The user must have put some stuff that does not belong there.
    version = ApToDict(o.metadata).get('version', '')
    current = 0 if o.timeDeleted else 1
    if not (version or current): continue
    name = o.name.rpartition('/')[-1]
    g_tarball_cache.append((version, current, name, o.generation))

    if len(g_tarball_cache) == GSSW_WARN_THRESHOLD:
      warn(f"The number of tarballs in gs://{gs_software}/{TARBALLS_DIR} is "
           f"over {GSSW_WARN_THRESHOLD}. Did you put something there that "
           f"does not belong?")
    if len(g_tarball_cache) >= GSSW_ERROR_THRESHOLD:
      fatal(f"The number of tarballs in gs://{gs_software}/{TARBALLS_DIR} is "
            f"over {GSSW_ERROR_THRESHOLD}. Clean it up.")

  g_tarball_cache.sort(reverse=True)  # In-place.
  debug(1, (f"Loaded directory of gs://{gs_software}/{TARBALLS_DIR}, "
            f"{len(g_tarball_cache)} potential candidate tarball files"))
  debug(2, 'Cached candidate list, in match-first order:\n',
           pp.pformat(g_tarball_cache,2))

#----- Artifact locators and their dispatch. -----------------------------------

DepFinder = Callable[[str,Opt[str]],Opt[str]]

def _find_tarball(name:str, ver:Opt[str]) -> Opt[str]:
  _ensure_gs_config()
  _ensure_tarball_cache()

  name_tgz = name + ".tar.gz"
  namever_tgz = f"{name}-{ver}.tar.gz" if ver else None
  for gver, __, gname, gener in g_tarball_cache:
    if ((gname == name_tgz and gver == ver) or
        (gname == namever_tgz and not gver)):
      res = f"gs://{gs_software}/{TARBALLS_DIR}{gname}#{gener}"
      debug(1, f"Found tarball {res} for name='{name}' and version='{ver}'")
      return 'gs ' + res

  debug(1, f"No tarball found for name='{name}' and version='{ver}'")
  return None


def _find_image(name:str, ver:Opt[str]) -> Opt[str]:
  _ensure_gs_config()
  _ensure_requests_session_and_gtoken()

  registry = f"{gs_location}.gcr.io"  # Registry service
  image = f"{g_project}/{name}"       # Image reference sans the tag.

  # Trade gtoken for the registry token.
  resp = g_session.get((f"https://{registry}/v2/token?service={registry}"
                        f"&scope=repository:{image}:pull"),
                       headers={'Authorization': g_gtoken})
  _check_200(resp)
  reg_token = 'Bearer ' + json.loads(resp.text)['token']

  # Check if image:tag exists with the HEAD request.
  ver = ver or 'latest'
  imageref = f"{registry}/{image}:{ver}"
  resp = g_session.head(f"https://{registry}/v2/{image}/manifests/{ver}",
                        headers={'Authorization': reg_token})
  if resp.status_code == 200:
    debug(1, f"Found existing image {imageref}")
    return 'image ' + imageref
  if resp.status_code == 404:
    debug(1, f"Image {imageref} does not exist")
    return None
  _check_200(resp)  # We know it's not 200; report a detailed error.


# Dependency checker map; also defines valid full target directive names.
depfind_dispatch:Map[str,DepFinder] = {
  'builder': _find_image,
  'image': _find_image,
  'tar': _find_tarball,
}

#==============================================================================#
# Evaluating dependencies and controlling build and artifact gathering.
#==============================================================================#

# my/dir/kaldi => kaldi,  kaldi => kaldi.
def _target_name(buildpath:str) -> str:
  return os.path.split(buildpath)[-1]

@dataclass(repr=False, eq=False)
class Target:
  "Complete description of a single build target."
  source:FileLine   # RO. FileLine('MillFile', 42)
  depfind:DepFinder # RO. Call this to find the artifact, if exists.
  kind:str          # RO, 'builder' | 'image' | 'tar'.
  buildpath:str     # RO. Usually a single word, but may be 'my/dir/kaldi'.
  version:Opt[str]  # RW  May be missing; the 'cxx' builder is an example.
  versvar:Opt[str]  # RO. E.g. '_KALDI_VER'.
  depends:Set       # RO. E.g. frozenset(cxx,mkl,cuda).
  substs:Map[str,str] = field(default_factory=dict) # RW.

  def __repr__(my):
    return ''.join(
      (' '.join((my.kind, my.buildpath, my.version or '', my.versvar or '')),
       my.depends and ' : ' or '', ' '.join(map(str, my.depends)),
       my.substs and ' : ' or '',
       ' '.join(f"{k}={v or ''}" for k, v in my.substs.items()),
       ' ## ', str(my.source)))

  # E.g., "mkl 2019.5 image us.gcr.io/my-project/mkl:2019.5"
  # None if not found, False to not gather (when for_gather only)
  def GetArtifact(my, for_gather:bool):
    if for_gather and my.kind == 'builder':
      debug(1, f"Skipping non-deployable builder {my.buildpath}")
      return False
    name = _target_name(my.buildpath)
    art = my.depfind(name, my.version)
    return ' '.join((name, my.version or '-', art)) if art else None


  # E. g., 'build mkl 2019.5 _MKL_VER=2019.5'
  # E. g., 'build cxx -'
  def GetBuildSpec(my) -> str:
    spec = ['build',
            _target_name(my.buildpath),
            my.version or '-',
            *(f"{k}={v}" for k, v in my.substs.items())]
    if my.versvar and my.version:
      spec.append(f"{my.versvar}={my.version}")
    return ' '.join(spec)


# Note that the data is mutable, only the references are frozen.
@dataclass(frozen=True)
class BuildPlan:
  "Build plan and dependency evaluator."
  _targets:Map[str,Target] = field(default_factory=dict)
  _skips:Set[str]   = field(default_factory=set)
  _starts:Set[str]  = field(default_factory=set)
  _forces:Set[str]  = field(default_factory=set)

  def __repr__(my):
    def setstr(s): return str(s) if s else '{}'
    return "\n".join(
      ("Combined Millfile:",
       *(">|   " + str(t) for t in my._targets.values()),
       f">| Skip set : {setstr(my._skips)}",
       f">| Start set: {setstr(my._starts)}",
       f">| Force set: {setstr(my._forces)}"))


  # Build a Target instance out of full directive, and return with its id name.
  def _ParseTarget(my, rec:TokenRecord) -> Tuple[str,Target]:
    fnl, (spec, depends, substs) = rec
    if len(spec) not in range(2, 4+1):
      parse_error(fnl, (f"The '{spec[0]}' directive requires 2 to 4 tokens, "
                        f"but {len(spec)} found in {spec}"))
    [kind, buildpath, version, versvar] = spec + [None]*(4-len(spec))
    if versvar:
      validate_buildvar(fnl, versvar)
    if versvar in substs:
      parse_error(fnl, (f"Version variable {versvar} is assigned within the "
                        f"substitutions section {substs}"))
    depfind = depfind_dispatch[kind]
    target = Target(source=fnl, depfind=depfind, kind=kind,
                    buildpath=buildpath, version=version, versvar=versvar,
                    depends=depends, substs=substs)
    # my/dir/kaldi => kaldi,  kaldi => kaldi.
    name = _target_name(buildpath)
    if name in depends:
      parse_error(fnl, (f"The target '{name}' depends on itself"))
    return name, target


  # Add or replace full (tar/image) target spec
  def _AddTarget(my, rec:TokenRecord) -> None:
    name, t = my._ParseTarget(rec)
    if name in my._targets:
      debug(2, (f"{t.source}: Replacing target {name}:\n"
                f">|   {my._targets[name]}\n>| with\n>|   {t}"))
    else:
      debug(2, f"{t.source}: Adding target {name}:\n>|   {t}")
    my._targets[name] = t


  # Add targets to set myset from addset. 'name' is for diagnostics only.
  # This is a workhorse behind a few other methods below. 'addset' can
  # be None or other non-iterable; this is treated as an empty set.
  def _AddToSet(my, name:str, myset:Set[str],
                    addset:Opt[Seq[str]], fnl=None) -> None:
    addset = set(addset or ())
    notintgt = addset - set(my._targets)
    if notintgt:
      err = f"Attempt to add unknown targets {notintgt} to the {name} set"
      if fnl:  # The skip directive in file.
        parse_error(fnl, err)
      else:    # Command-line parameter for the force and start sets.
        fatal(err)
    myset.update(addset)
    debug(1, f"{fnl}: " if fnl else '',
          f"Adding {addset} to {name} set; full {name} set is now {myset}")


  # The skip directive.
  def _AddSkips(my, rec:TokenRecord) -> None:
    # 'skip cuda mkl cxx ...'
    validate_nocolon(rec, mintok=2)
    fnl, (spec, *__) = rec
    my._AddToSet("skip", my._skips, spec[1:], fnl=fnl)


  # The ver directive, update version and, optionally, subst vars of a target.
  def _UpdateTarget(my, rec:TokenRecord) -> None:
    # 'ver cuda 12.5.0 [ _CUDA_URL=http://foo ...]'
    validate_nocolon(rec, mintok=3)
    fnl, (spec, *__) = rec
    [tname, newver] = spec[1:3]
    newsubsts = parse_var_map(fnl, spec[3:])
    tgt = my._targets.get(tname)
    # Holy buttload of checks. *Of course* I did not miss any corner cases!
    if not tgt:
      parse_error(fnl, f"Unknown target '{tname}' in the 'ver' directive")
    if tgt.versvar in newsubsts:
      parse_error(fnl, (f"Version variable '{tgt.versvar}' of the target "
                        f"'{tname}' cannot be directly updated by the 'var' "
                        f"directive substitution update clause {spec[3:]}"))
    if not tgt.version and not tgt.versvar:
      parse_error(fnl, (f"Target '{tname}' is declared at {tgt.source} as "
                        f"unversioned (it has neither version nor a version "
                        f"variable)."))
    if not tgt.versvar and not newsubsts:
      parse_error(fnl, (f"Target '{tname}' declared at {tgt.source} has no "
                        f"version variable, and the 'ver' clause does not "
                        f"change or set any substitution variables of the "
                        f"target. The version change alone would not cause "
                        f"any change in the build settings, and would thus "
                        f"produce the same artifact as before, but with a "
                        f"different version. This is a consistency violation."))
    if not tgt.versvar and tgt.version != newver:
      warn(f"{fnl}: Target '{tname}' declared at {tgt.source} has no version "
           f"variable. Make sure that the updated substitutions {spec[3:]} "
           f"will in fact produce the version '{newver}' which you are "
           f"setting.")
    debug(2, (f"{fnl}: Changing target {tname} version "
              f"from {tgt.version} to {newver}"))
    tgt.version = newver
    if newsubsts:
      debug(2, (f"{fnl}: Combining/overriding target {tname} subst vars:\n"
                f">|   {tgt.substs}\n>| with:\n>|   {newsubsts}"))
    tgt.substs.update(newsubsts)


  # Process a directive line. This is the semantic dispatch of the parser.
  def AddDirective(my, rec:TokenRecord) -> None:
    # Dispatch on first token in the record:
    # (FNL, ([THIS ... ))
    direc = rec[1][0][0]
    if direc in depfind_dispatch:
      my._AddTarget(rec)
    elif direc == 'ver':
      my._UpdateTarget(rec)
    elif direc == 'skip':
      my._AddSkips(rec)
    else:
      parse_error(rec[0], (f"Unknown directive '{direc}'. Known directives are "
                           f"{[*depfind_dispatch, 'ver', 'skip']}"))


  # From command line. Looks args.{rebuild_all,targets,force}.
  # Must be called the last, when my._targets is no longer augmented.
  def FromCommandLineArgs(my, targets:Opt[Set[str]], force:Opt[Set[str]],
                              rebuild_all:bool, **kwdummy) -> None:
    if rebuild_all:
      my._AddToSet("start", my._starts, my._targets)
      my._AddToSet("force", my._forces, my._targets)
    else:
      my._AddToSet("start", my._starts, targets)
      my._AddToSet("force", my._forces, force)


  # Check if any defined target depends on an undefined one.
  def _ValidateDanglingDeps(my) -> None:
    known = set(my._targets)
    missing = []
    for k, t in my._targets.items():
      unk = t.depends - known
      if unk: missing.append((t.source, k, unk))
    if missing:
      fatal(f"The following dependencies have no rules to build them:",
            *(f"\n>| {s}: {t}: {' '.join(d)}" for s, t, d in missing))


  # Construct an "uninformed" build order:
  def BuildOrder(my) -> List[Set[str]]:
    my._ValidateDanglingDeps()
    # No explicit targets = build all except explicit skips.
    starts:Set[str] = set(my._starts or my._targets) - my._skips
    debug(2, f"Inferring order from starting targets {starts}")

    # Build closure off starting targets. Copy their dependency sets, we'll
    # mutate them in-place during toposorting.
    clos = {}; seed = starts
    while seed:
      add = {k:set(my._targets[k].depends) for k in seed}
      seed = reduce(set.union, add.values()) - set(clos)
      clos.update(add)
    debug(2, f"Closure of selected dependencies: {clos}")

    # Now toposort with the closure with the usual Kahn's, and collect batches
    # of satisfied dependencies into an ordered list
    res = []
    while True:
      rank = set(filterfalse(clos.get, clos))
      if not rank: break
      for k in rank: del clos[k]
      for k in clos: clos[k] -= rank
      res.append(rank)
    if clos:
      fatal(f"Circular dependencies found: {clos}")
    debug(1, f"Evaluated build order w.r.t. dependencies: {res}")
    # Note that res may contains skips if they are dependencies of something.
    # This is not yet fatal, but will be if any of them is out-of-date.
    return res


  # Helpers to avoid excessively long lambdas.
  def _GetBuildSpec(my, t) -> str:
    return my._targets[t].GetBuildSpec()

  def _GetArtifact(my, t, for_gather) -> Opt[str]:
    return my._targets[t].GetArtifact(for_gather)

  # This is the where we convert build order into build sequence: collect what
  # is missing and must be built, for the first invocation of the tool.
  def ConstructBuild(my, plan) -> List[List[str]]:
    # Pretend the artifact is not there if rebuilding by force.
    def _GetArtifactForBuild(t:str):
      return None if t in my._forces else my._GetArtifact(t, for_gather=False)

    res, blockers = [], set()
    for tset in plan:
      dirty = set(filterfalse(_GetArtifactForBuild, tset))
      if not dirty: continue
      if blockers:
        fatal(f"Target(s) {blockers} are explicitly prevented from being built "
              f"with the 'skip' directive, but one or more target in {dirty} "
              f"are out-of-date and depend on it. As a rule, mark only "
              f"independent targets to be skipped.")
      blockers.update(dirty.intersection(my._skips))
      # Turn each element of 'dirty' into a build directive.
      res.append(list(map(my._GetBuildSpec, dirty)))
    return res


  # For the post-build gather phase, check that artifacts are really there and
  # return them for assembling the R/O software disk. It's an error if any
  # artifact is missing, and a damn tricky one to track down!
  def ConstructGather(my, plan):
    errs = set()
    # Accumulate all errors for reporting in one pass as a side effect. Note
    # that this is the only place when we distinguish None and False for the
    # artifact: None is an error (artifact not found), and False stands to skip
    # gathering (a builder, not yielding an artifact) without an error.
    def _GetArtifactForGather(t:str):
      art = my._GetArtifact(t, for_gather=True)
      if art is None: errs.add(t)
      return art

    # At the gather stage the order is irrelevant. Lump all artifacts into a
    # single flat sequence for collecting.
    res = list(filter(None, map(_GetArtifactForGather, chain(*plan))))
    if errs:
      fatal(f"Build did not produce expected artifacts for targets {errs}. "
            f"Check the build logs, whether the artifact type (tar or image) "
            f"is correct, and whether the build control file places the "
            f"artifact where it should be, with the correct version tarball "
            f"metadatum or image tag.")
    return res

#==============================================================================#
# Main entrypoint.
#==============================================================================#

def _unsafe_main():
  global g_project, gs_location, gs_software
  args = parse_args()
  g_project = args.project
  gs_location = args.gs_location
  gs_software = args.gs_software

  build_plan = BuildPlan()

  x = _read_real_files(args.files)
  for x in _tokenize(x):
    build_plan.AddDirective(x)

  # Process command line args only when all files are loaded.
  build_plan.FromCommandLineArgs(**vars(args))

  debug(1, f"Load complete. {build_plan}")
  plan = build_plan.BuildOrder()

  # Output builder or gatherer directives to stdout.
  if not args.gather:
    # Doing build.
    buildspec:Seq[Seq[str]] = build_plan.ConstructBuild(plan)
    for batch in buildspec:
      for direc in batch:
        print(direc)
      print('wait')
    if not buildspec:
      info(f"Examined build targets {sorted(chain(*plan))} are all up-to-date")

  else:
    # Doing gather.
    for direc in build_plan.ConstructGather(plan):
      print(direc)

def _main():
  try:
    _unsafe_main()
  except _Error as e:
    fatal(e)

if __name__ == '__main__':
  _main()
  exit(0)
