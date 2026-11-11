# List the available recipes
help:
    @just --list

# Install pclaude and pcodex into ~/.local/bin and build the image (extra args go to podman build)
[group('setup')]
install *args:
    ./install.sh {{args}}

# Run the tests (fake podman; the Keychain sync part needs macOS)
[group('dev')]
test:
    ./test.sh
