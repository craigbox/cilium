include ../../../Makefile.defs

BUILDDIR := "$(CURDIR)/stage/cilium-$(VERSION)"

build: clean
	mkdir -p $(BUILDDIR)
	@$(CURDIR)/../cp-dirs.sh $(BUILDDIR)
	cp -v ../../../Dockerfile $(BUILDDIR)
	find $(BUILDDIR) -name ".*" -prune ! -name ".git"  -exec rm -rf {} \;
	docker build -t "cilium:$(DOCKER_IMAGE_TAG)" $(BUILDDIR)

clean:
	ls -d ./* | grep -vE "Makefile|clang-3.8.1.key" | xargs rm -rf

.PHONY: clean build force
force :;
