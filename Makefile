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
	&& mkdir -p dist && mv ${NAME}.app dist/${NAME}.app

.PHONY: build-windows
build-windows: info
	@fyne package -os windows -name ${NAME} -appVersion ${VERSION} -appID ${ID} -icon icon.png -release \
	&& mkdir -p dist && mv ${NAME}.exe dist/${NAME}.exe

.PHONY: build-linux
build-linux: info
	@fyne package -os linux -name ${NAME} -appVersion ${VERSION} -appID ${ID} -icon icon.png -release \
	&& mkdir -p dist && mv ${NAME}.tar.xz dist/${NAME}-linux.tar.xz

.PHONY: install-darwin
install-darwin: build-darwin
	@cp -r dist/${NAME}.app /Applications
