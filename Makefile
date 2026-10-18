.PHONY: build install uninstall test test-multiarch bench release clean

build:
	zig build -Doptimize=ReleaseFast

install: build
	cp zig-out/bin/dent /usr/local/bin/dent

uninstall:
	rm -f /usr/local/bin/dent

test: build
	zig build test
	bash test-coverage/integration.sh
	bash test-coverage/discovery.sh

test-multiarch:
	docker buildx build --platform linux/arm64 -f test-coverage/Dockerfile --target integration .
	docker buildx build --platform linux/amd64 -f test-coverage/Dockerfile --target integration .

bench: build
	zig build-exe bench/main.zig --name bench-runner -OReleaseFast && ./bench-runner && rm -f bench-runner bench-runner.o
	bash bench/vs_git.sh

release:
	rm -rf release && mkdir release
	zig build -Doptimize=ReleaseFast -Dtarget=aarch64-macos
	tar -czf release/dent-darwin-arm64.tar.gz -C zig-out/bin dent
	zig build -Doptimize=ReleaseFast -Dtarget=x86_64-macos
	tar -czf release/dent-darwin-amd64.tar.gz -C zig-out/bin dent
	zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-gnu
	tar -czf release/dent-linux-arm64.tar.gz -C zig-out/bin dent
	zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu
	tar -czf release/dent-linux-amd64.tar.gz -C zig-out/bin dent
	cd release && shasum -a 256 *.tar.gz > checksums.txt

clean:
	rm -rf zig-out .zig-cache bench-runner bench-runner.o release
