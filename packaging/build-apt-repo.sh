#!/usr/bin/env bash
#
#  Turns the built .deb into a real APT repository you can publish on GitHub
#  Pages, so anyone can run `sudo apt install anonx`.
#
#     ./packaging/build-deb.sh          # build the package first
#     ./packaging/build-apt-repo.sh     # then the repo -> packaging/repo/
#
#  Publish packaging/repo/ on GitHub Pages (Settings -> Pages -> /docs or a
#  gh-pages branch), then on any machine:
#
#     echo "deb [trusted=yes] https://<user>.github.io/anonx ./" \
#          | sudo tee /etc/apt/sources.list.d/anonx.list
#     sudo apt update && sudo apt install anonx
#
#  [trusted=yes] skips GPG. To sign it properly instead, see SIGNING below.
#
set -e

SRC=$(cd "$(dirname "$0")/.." && pwd)
DIST="$SRC/packaging/dist"
REPO="$SRC/packaging/repo"

command -v dpkg-scanpackages >/dev/null 2>&1 || {
  echo "need dpkg-dev:  sudo apt install dpkg-dev"; exit 1; }
ls "$DIST"/*.deb >/dev/null 2>&1 || {
  echo "no .deb found — run ./packaging/build-deb.sh first"; exit 1; }

rm -rf "$REPO"; mkdir -p "$REPO"
cp "$DIST"/*.deb "$REPO/"

cd "$REPO"
dpkg-scanpackages --multiversion . > Packages
gzip -9c Packages > Packages.gz
command -v apt-ftparchive >/dev/null 2>&1 && apt-ftparchive release . > Release

echo "repo ready: $REPO"
echo
echo "  1) commit packaging/repo/ and publish it with GitHub Pages"
echo "  2) on the target machine:"
echo "     echo 'deb [trusted=yes] https://<user>.github.io/anonx ./' | sudo tee /etc/apt/sources.list.d/anonx.list"
echo "     sudo apt update && sudo apt install anonx"
echo
echo "SIGNING (optional, drops the [trusted=yes]):"
echo "     gpg --gen-key"
echo "     gpg --clearsign -o InRelease Release"
echo "     gpg --armor --export <keyid> > anonx.gpg   # users put this in /etc/apt/keyrings/"
