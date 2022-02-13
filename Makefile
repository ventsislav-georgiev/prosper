NAME=Prosper
ID=com.ventsislav-georgiev.prosper
VERSION=0.0.0

.PHONY: info
info:
	@echo ${NAME} v${VERSION}

.PHONY: build-darwin
build-darwin: info
	@fyne package -os darwin -name ${NAME} -appVersion ${VERSION} -appID ${ID} -release \
	&& plutil -insert LSUIElement -bool true ${NAME}.app/Contents/Info.plist \
	&& mkdir -p dist && mv ${NAME}.app dist/${NAME}.app \
	&& cp dist/${NAME}.app/Contents/MacOS/prosper dist/bin-darwin-$(shell go env GOARCH) \
	&& gzip dist/bin-darwin-$(shell go env GOARCH)

.PHONY: build-windows
build-windows: info
	@fyne package -os windows -name ${NAME} -appVersion ${VERSION} -appID ${ID} -release \
	&& mkdir -p dist && mv ${NAME}.exe dist/${NAME}.exe \
	&& cp dist/${NAME}.exe dist/bin-windows-$(shell go env GOARCH) \
	&& gzip dist/bin-windows-$(shell go env GOARCH)

.PHONY: build-linux
build-linux: info
	@fyne package -os linux -name ${NAME} -appVersion ${VERSION} -appID ${ID} -release \
	&& mkdir -p dist && mv ${NAME}.tar.xz dist/${NAME}-linux-$(shell go env GOARCH).tar.xz \
	&& tar -xf dist/${NAME}-linux-$(shell go env GOARCH).tar.xz usr/local/bin/prosper \
	&& mv usr/local/bin/prosper dist/bin-linux-$(shell go env GOARCH) \
	&& gzip dist/bin-linux-$(shell go env GOARCH)

.PHONY: install-darwin
install-darwin: build-darwin
	@cp -r dist/${NAME}.app /Applications
