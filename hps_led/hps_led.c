#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <inttypes.h>
#include <errno.h>

#include <sys/mman.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>

#define PERIPHERAL_BASE_ADDR 0xFF200000
#define LED_IO_OFFSET 0
#define LED_IO_SIZE 2

int main(int argc, char *argv[]) {
	if (argc < 2) {
		printf("Usage: hps_led value\n");
		return -1;
	}

	uint8_t value = strtol(argv[1], NULL, 0);

	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		perror("Opening /dev/mem");
		return errno;
	}

	volatile uint8_t *base = (uint8_t *)mmap(NULL, LED_IO_SIZE,
		PROT_READ | PROT_WRITE,
		MAP_SHARED, fd, PERIPHERAL_BASE_ADDR + LED_IO_OFFSET);
	if (base == MAP_FAILED) {
		perror("In mmap");
		close(fd);
		return errno;
	}

	*base = value;
	printf("Value set to: 0x%02x\n", value);

	int result = munmap((void *)base, LED_IO_SIZE);
	if (result != 0) {
		perror("munmap");
	}
	close(fd);
	return 0;
}
