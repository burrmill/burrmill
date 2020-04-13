All *.deb package files that you put into this directory will be installed.
Be mindful of their dependencies: the packages are installed with `dpkg -i`,
which, unlike apt-get, does not try to download package dependencies, so that
image build will fail.

Thread lightly: build and image, spin off an f1-micro instance with it, upload
packages to it and test if they install cleanly, or some depndencies are absent.
If they are, and available in the normal Debian feed (`apt show <package` will
tell you, after you download the database with `apt update`), add these
dependencies to etc/imaging/addons/user_vars.inc.sh, `USER_APT_PACKAGES`. If
not, you are starting to build a [Frankendebian](
https://wiki.debian.org/DontBreakDebian#Don.27t_make_a_FrankenDebian), so think
if you can avoid that.
