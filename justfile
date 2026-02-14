default:
    just --list

run:
    odin run src

build:
    odin build src -debug

release:
    odin build src -o=speed
