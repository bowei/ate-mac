.PHONY: all image app dmg test clean

all: dmg

image:
	scripts/build-image.sh

app:
	scripts/build-app.sh

dmg: app
	scripts/build-dmg.sh

test:
	swift test --package-path app
	python3 -m unittest discover -s app/Tests/stats

clean:
	rm -rf build app/.build
