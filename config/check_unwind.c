#include <libunwind-ptrace.h>

/* Link probe only. The build never executes this function. */
int
main(void)
{
	void *context = _UPT_create(0);
	unw_addr_space_t space = unw_create_addr_space(&_UPT_accessors, 0);

	_UPT_destroy(context);
	unw_destroy_addr_space(space);
	return 0;
}
