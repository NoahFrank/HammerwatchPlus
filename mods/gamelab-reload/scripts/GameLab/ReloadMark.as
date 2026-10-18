// gamelab-reload: the reload-mark scenario rewrites MARK while the game runs
// (runner step write_mod_file) and then loads another level, to measure whether the
// engine recompiles scripts from disk on a level load. The runner puts this file back.
namespace GameLabReload
{
	const string MARK = "A";
}

namespace Modules
{
	class GameLabReloadModule : Module
	{
		GameLabReloadModule()
		{
			super("gamelab-reload");
			print("[GL-reload] mark=" + GameLabReload::MARK + " level=" + GetCurrentLevelFilename());
		}
	}
}
