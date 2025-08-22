ESP_VERSION := 3.2.2
all: configs flags

configs: configs.h
configs.h: configs.h.in
	@cp $< $@

flags: compile_flags.txt
compile_flags.txt: compile_flags.txt.in
	@sed "s|{HOME}|${HOME}|g" $< | sed "s|{ESP_VERSION}|${ESP_VERSION}|g" > $@

.PHONY: all configs flags
