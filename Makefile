.PHONY: all image app dmg clean

all: dmg

image:
	scripts/build-image.sh

app:
	scripts/build-app.sh

dmg: app
	scripts/build-dmg.sh

clean:
	rm -rf build app/.build
