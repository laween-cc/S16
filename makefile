# Simple makefile for testing
# I may make a disk tool later on

# floppy image
build/S16-floppy.img: build/BOOT.BIN build/S16.SYS
	@mkdir -p $(dir $@)
	dd if=/dev/zero of=$@ bs=512 count=2880
# Format to fat12
	mkfs.fat -F 12 $@
# Inject the boot sector
	dd if=build/BOOT.BIN of=$@ bs=1 seek=62 count=448 conv=notrunc
# Copy the kernel to the images root
	mcopy -i $@ build/S16.SYS ::S16.SYS
	@sync

build/BOOT.BIN:
	curl -o BOOT.ASM https://raw.githubusercontent.com/laween-cc/S16-boot/refs/heads/master/BOOT.ASM
# I'll use NASM to assemble
	@mkdir -p $(dir $@)
	nasm -f bin BOOT.ASM -o $@
# Get rid of the source file
	rm BOOT.ASM

build/S16.SYS: SOURCE/S16.ASM
	@mkdir -p $(dir $@)
# I'll use NASM
	nasm -f bin $< -o $@

# Phony stuff 
.PHONY: clean qemu

clean:
	rm -r build/* --verbose --one-file-system --preserve-root

qemu: build/S16-floppy.img
	qemu-system-i386 -drive file=$<,format=raw,if=floppy -boot order=a