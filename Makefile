NAME=Prosper
ID=com.ventsislav-georgiev.prosper
VERSION=0.0.0

.PHONY: info
info:
	@echo ${NAME} v${VERSION}

.PHONY: build-darwin
build-darwin: info
	@fyne package -os darwin -name ${NAME} -appVersion ${VERSION} -appID ${ID} -icon icon.png -release \
	&& plutil -insert LSUIElement -bool true ${NAME}.app/Contents/Info.plist \
	&& mkdir -p dist && mv ${NAME}.app dist/${NAME}.app \
	&& cp dist/${NAME}.app/Contents/MacOS/prosper dist/bin-darwin \
	&& gzip dist/bin-darwin

.PHONY: build-windows
build-windows: info
	@fyne package -os windows -name ${NAME} -appVersion ${VERSION} -appID ${ID} -icon icon.png -release \
	&& mkdir -p dist && mv ${NAME}.exe dist/${NAME}.exe \
	&& cp dist/${NAME}.exe dist/bin-windows \
	&& gzip dist/bin-windows

.PHONY: build-linux
build-linux: info
	@fyne package -os linux -name ${NAME} -appVersion ${VERSION} -appID ${ID} -icon icon.png -release \
	&& mkdir -p dist && mv ${NAME}.tar.xz dist/${NAME}-linux.tar.xz \
	&& tar -xf dist/Prosper-linux.tar.xz usr/local/bin/prosper \
	&& mv usr/local/bin/prosper dist/bin-linux \
	&& gzip dist/bin-linux

.PHONY: install-darwin
install-darwin: build-darwin
	@cp -r dist/${NAME}.app /Applications
