#!/bin/sh
# Concatenate the Lua module parts into dist/Baritone.lua
set -e
cd "$(dirname "$0")"
mkdir -p dist
cat lua/parts/*.lua > dist/Baritone.lua
echo "built dist/Baritone.lua ($(wc -l < dist/Baritone.lua) lines)"
