#include <stdio.h>
#include <stdbool.h>
#include <stdlib.h>
#include <unistd.h>
#include <inttypes.h>
#include <errno.h>
#include <strings.h>

#include <sys/mman.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>

#define GPIO_BASE_ADDR 0xFF708000
#define GPIO_OFFSET 0
#define GPIO_SIZE 8

int main(int argc, char *argv[]) {
	if (argc < 3) {
		printf("Usage: gpio set|get id [value]\n");
		return -1;
	}

	bool set = strcasecmp("set", argv[1]) == 0;

	uint8_t id = strtol(argv[2], NULL, 0);
	bool value = false;
	if (set) {
		if (argc < 4) {
			printf("No value to set provided\n");
			return -1;
		} else {
			value = strcasecmp("1", argv[3]) == 0;
  		}
        }

	printf("* Operation: %s\n", set ? "set" : "get");
	printf("* GPIO: %d\n", id);
	if (set) {
		printf("* %s\n", value ? "Set": "Reset");
	}

	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		perror("Opening /dev/mem");
		return errno;
	}

	volatile uint32_t *base = (uint32_t *)mmap(NULL, GPIO_SIZE,
		PROT_READ | PROT_WRITE,
		MAP_SHARED, fd, GPIO_BASE_ADDR + GPIO_OFFSET);
	if (base == MAP_FAILED) {
		perror("In mmap");
		close(fd);
		return errno;
	}

	printf("-Dirs:\t%032b\n", *(base + 1));
	printf("-Vals:\t%032b\n", *base);

	if (!set) {
		bool value = (*(base) & (1 << id)) != 0;
		printf("GPIO%d: %d\n", id, value);
	} else {
		*(base + 1) |= (1 << id);
		if (value) {
			*(base) |= (1 << id);
		} else {
			*(base) &= ~(1 << id);
		}
	}
	printf("+Dirs:\t%032b\n", *(base + 1));
	printf("+Vals:\t%032b\n", *base);

	int result = munmap((void *)base, GPIO_SIZE);
	if (result != 0) {
		perror("munmap");
	}
	close(fd);
	return 0;
}
