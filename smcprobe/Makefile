CFLAGS = -O2 -Wall
LIBS = -framework IOKit -framework CoreFoundation

all: smcprobe fantest

smcprobe: smcprobe.c
	clang $(CFLAGS) -o $@ $< $(LIBS)

fantest: fantest.c
	clang $(CFLAGS) -o $@ $< $(LIBS)

clean:
	rm -f smcprobe fantest

.PHONY: all clean
