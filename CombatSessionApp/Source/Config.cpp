#include "Config.h"

#include "Platform.h"

#include <cctype>
#include <cstdlib>
#include <fstream>
#include <sstream>

namespace fs = std::filesystem;

namespace cs {
namespace {

// The settings file is a flat object of strings, numbers and booleans, so a
// full JSON parser would be more machinery than the format warrants. This
// reads exactly that shape and ignores anything else.
std::string FindValue(const std::string& text, const std::string& key) {
    const std::string needle = "\"" + key + "\"";
    size_t pos = text.find(needle);
    if (pos == std::string::npos) return {};

    pos = text.find(':', pos + needle.size());
    if (pos == std::string::npos) return {};
    ++pos;

    while (pos < text.size() && std::isspace(static_cast<unsigned char>(text[pos]))) ++pos;
    if (pos >= text.size()) return {};

    if (text[pos] == '"') {
        std::string out;
        for (size_t i = pos + 1; i < text.size(); ++i) {
            if (text[i] == '\\' && i + 1 < text.size()) { out += text[++i]; continue; }
            if (text[i] == '"') break;
            out += text[i];
        }
        return out;
    }

    const size_t end = text.find_first_of(",}\r\n", pos);
    return text.substr(pos, (end == std::string::npos ? text.size() : end) - pos);
}

bool Has(const std::string& text, const std::string& key) {
    return text.find("\"" + key + "\"") != std::string::npos;
}

std::string Escape(const std::string& text) {
    std::string out;
    for (const char c : text) {
        if (c == '"' || c == '\\') out += '\\';
        out += c;
    }
    return out;
}

} // namespace

//------------------------------------------------------------------------------

bool LooksLikeFlavor(const fs::path& dir) {
    if (dir.empty()) return false;
    std::error_code ec;
    return fs::exists(dir / "Logs", ec)
        && fs::exists(dir / "Interface" / "AddOns", ec);
}

fs::path DefaultConfigPath() {
    return ExecutablePath().parent_path() / "settings.json";
}

bool Config::Load(const fs::path& path) {
    std::ifstream in(path);
    if (!in) return false;

    std::stringstream ss;
    ss << in.rdbuf();
    const std::string text = ss.str();

    wowPath = FindValue(text, "wowPath");

    // Booleans are read as "true only if the file says true", so a key that is
    // absent, misspelled or garbled leaves the option off rather than on. The
    // failure mode of a damaged settings file should be a program that does
    // nothing, not one that does something unasked.
    startAtLogin   = FindValue(text, "startAtLogin")   == "true";
    startMinimized = FindValue(text, "startMinimized") == "true";
    archiveRaw     = FindValue(text, "archiveRaw")     == "true";
    minimizeToTray = FindValue(text, "minimizeToTray") == "true";

    // Read only when present, because this one defaults on: forcing it off for
    // an absent key would silence the alert for every settings file written
    // before the key existed.
    if (Has(text, "soundEnabled")) {
        soundEnabled = FindValue(text, "soundEnabled") == "true";
    }

    // Empty is meaningful here - it is the system notification sound - so an
    // absent key and a present empty one mean the same thing and both are fine.
    reloadSound = FindValue(text, "reloadSound");

    alertRepeat = (FindValue(text, "alertRepeat") == "every")
                ? AlertRepeat::Every : AlertRepeat::Once;

    // Defaults off, so an absent key and "false" agree and no guard is needed.
    alertOnNewSessions = FindValue(text, "alertOnNewSessions") == "true";

    auto Number = [&text](const char* key, int& target, int low, int high) {
        if (!Has(text, key)) return;
        const int value = std::atoi(FindValue(text, key).c_str());
        if (value >= low && value <= high) target = value;
    };

    // Clamped rather than trusted. A repeat of zero seconds would be a tight
    // loop playing a sound, which is a thing a hand-edited file could ask for
    // by accident and nothing should ever actually do.
    Number("pollSeconds",        pollSeconds,        1, 300);
    Number("repeatSeconds",      repeatSeconds,      5, 3600);
    Number("rawLimit",           rawLimit,           1, 100000);
    Number("pendingLimit",       pendingLimit,       1, 100000);
    Number("settleSeconds",      settleSeconds,      1, 3600);
    Number("closedAfterSeconds", closedAfterSeconds, 1, 86400);
    return true;
}

bool Config::Save(const fs::path& path) const {
    std::ofstream out(path, std::ios::binary);
    if (!out) return false;

    out << "{\n";
    out << "  \"wowPath\": \"" << Escape(wowPath) << "\",\n";
    out << "  \"startAtLogin\": "   << (startAtLogin   ? "true" : "false") << ",\n";
    out << "  \"startMinimized\": " << (startMinimized ? "true" : "false") << ",\n";
    out << "  \"archiveRaw\": "     << (archiveRaw     ? "true" : "false") << ",\n";
    out << "  \"minimizeToTray\": " << (minimizeToTray ? "true" : "false") << ",\n";
    out << "  \"soundEnabled\": "   << (soundEnabled   ? "true" : "false") << ",\n";
    out << "  \"reloadSound\": \"" << Escape(reloadSound) << "\",\n";
    out << "  \"alertRepeat\": \""
        << (alertRepeat == AlertRepeat::Every ? "every" : "once") << "\",\n";
    out << "  \"alertOnNewSessions\": "
        << (alertOnNewSessions ? "true" : "false") << ",\n";
    out << "  \"pollSeconds\": " << pollSeconds << ",\n";
    out << "  \"repeatSeconds\": " << repeatSeconds << ",\n";
    out << "  \"rawLimit\": " << rawLimit << ",\n";
    out << "  \"pendingLimit\": " << pendingLimit << ",\n";
    out << "  \"settleSeconds\": " << settleSeconds << ",\n";
    out << "  \"closedAfterSeconds\": " << closedAfterSeconds << "\n";
    out << "}\n";
    return out.good();
}

fs::path Config::LogsDir() const   { return fs::path(wowPath) / "Logs"; }
fs::path Config::WtfRoot() const   { return fs::path(wowPath) / "WTF" / "Account"; }
fs::path Config::RawDir() const    { return DefaultConfigPath().parent_path() / "Raw"; }
fs::path Config::AddOnsDir() const { return fs::path(wowPath) / "Interface" / "AddOns"; }

bool Config::IsValid() const {
    return LooksLikeFlavor(fs::path(wowPath));
}

} // namespace cs
