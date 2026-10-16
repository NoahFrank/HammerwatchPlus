namespace HWP
{
	const string VERSION = "0.1.0";

	void Log(const string &in module, const string &in msg)
	{
		print("[HWP:" + module + "] " + msg);
	}

	void LogError(const string &in module, const string &in msg)
	{
		PrintError("[HWP:" + module + "] " + msg);
	}
}
