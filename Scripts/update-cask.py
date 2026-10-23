#!/usr/bin/env python3
"""Generate the tap entry from the exact immutable release archive."""
import argparse
import hashlib
import pathlib
import re

parser = argparse.ArgumentParser()
parser.add_argument("--version", required=True)
parser.add_argument("--archive", type=pathlib.Path, required=True)
parser.add_argument("--tap", type=pathlib.Path, required=True)
args = parser.parse_args()
if not re.fullmatch(r"\d+\.\d+\.\d+", args.version):
    parser.error("version must have the form 1.2.3")
digest = hashlib.sha256(args.archive.read_bytes()).hexdigest()
cask = '''cask "glut" do
  version "VERSION"
  sha256 "CHECKSUM"

  url "https://github.com/theitger/glut/releases/download/v#{version}/Glut-#{version}.zip"
  name "Glut"
  desc "Temperature monitoring and fan control"
  homepage "https://github.com/theitger/glut"

  depends_on macos: :sonoma

  app "Glut.app"

  zap trash: "~/Library/Preferences/dev.theitger.glut.plist"

  caveats <<~EOS
    Glut is ad-hoc signed and is not Apple-notarized.
    If macOS blocks the first launch, allow Glut in
    System Settings > Privacy & Security > Open Anyway.
  EOS
end
'''.replace("VERSION", args.version).replace("CHECKSUM", digest)
destination = args.tap / "Casks" / "glut.rb"
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(cask)
print(destination)
