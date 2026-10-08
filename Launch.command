#!/bin/zsh
set -eu
cd "${0:A:h}"
if [[ ! -x 'dist/GO Tone Bridge.app/Contents/MacOS/GO Tone Bridge' ]]; then
  ./build.command
fi
open 'dist/GO Tone Bridge.app'
