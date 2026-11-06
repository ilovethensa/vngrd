PYTHON ?= python3
RUN := bin/vngrd-tests

.PHONY: help list check-host check-boot check-all clean

help:
	@echo "make list        list every case"
	@echo "make check-host  unit + image tiers (no VM, seconds) — run on every build"
	@echo "make check-boot  boot tier (qemu + TPM, minutes)"
	@echo "make check-all   every tier"
	@echo "make clean       drop repository-local state and results"

list:
	$(RUN) list

check-host:
	mkdir -p results
	$(RUN) run --tier unit image --junit results/host.xml --json results/host.json

check-boot:
	mkdir -p results
	$(RUN) run --tier boot --junit results/boot.xml --json results/boot.json

check-all:
	mkdir -p results
	$(RUN) run --tier all --junit results/all.xml --json results/all.json

clean:
	rm -rf .state .cache results
