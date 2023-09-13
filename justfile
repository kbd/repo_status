set positional-arguments

build *args:
  zig build-exe repo_status.zig "$@"

build-release *args:
  zig build-exe -OReleaseFast repo_status.zig "$@"
