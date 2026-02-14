default:
    just --list

run:
    odin run src

build:
    odin build src -debug

just release:
    odin build src -o=speed