// HWP::Settings - the local player's HammerwatchPlus preferences.
// Stored in the current town record's hwp data as "settings.<name>", so they
// live in the persistent save and follow the save slot. Modules read them with
// a default; a settings GUI arrives with the first module that needs toggles.
//
//   bool split = HWP::Settings::GetBool("architect.split_cost", true);
//   HWP::Settings::SetBool("architect.split_cost", false);
namespace HWP
{
	namespace Settings
	{
		const string PREFIX = "settings.";

		HWP::DataBag@ Bag() { return HWP::SaveData::Town(); }

		bool GetBool(const string &in name, bool def = false) { return Bag().GetBool(PREFIX + name, def); }
		int GetInt(const string &in name, int def = 0) { return Bag().GetInt(PREFIX + name, def); }
		float GetFloat(const string &in name, float def = 0) { return Bag().GetFloat(PREFIX + name, def); }
		string GetString(const string &in name, const string &in def = "") { return Bag().GetString(PREFIX + name, def); }

		void SetBool(const string &in name, bool val) { Bag().SetBool(PREFIX + name, val); }
		void SetInt(const string &in name, int val) { Bag().SetInt(PREFIX + name, val); }
		void SetFloat(const string &in name, float val) { Bag().SetFloat(PREFIX + name, val); }
		void SetString(const string &in name, const string &in val) { Bag().SetString(PREFIX + name, val); }
		void Reset(const string &in name) { Bag().Remove(PREFIX + name); }
	}
}
