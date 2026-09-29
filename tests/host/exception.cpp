extern "C" int throw_and_catch(void)
{
	try {
		throw 1;
	} catch (int x) {
		return x + 4;
	}
}

extern "C" void throw_out(void)
{
	throw 2;
}
