#include "youtube_dl.h"

YoutubeDl::YoutubeDl()
{

}

QString YoutubeDl::path = QString();
QString YoutubeDl::pythonCaFile = QString();

QString YoutubeDl::expectedReleaseAssetName() {
#if defined(Q_OS_WIN)
    return "yt-dlp_win.zip";   // onedir bundle — fast cold start
#elif defined(Q_OS_MAC)
    return "yt-dlp_macos.zip"; // onedir bundle — fast cold start
#else
    return "yt-dlp";           // Linux: still the .py script
#endif
}

QString YoutubeDl::bundledBinaryName() {
    // yt-dlp's PyInstaller bundles name the binary after the asset:
    // yt-dlp_macos.zip → yt-dlp_macos, yt-dlp_win.zip → yt-dlp.exe (the
    // x64 variant — _x86 / _arm64 use different filenames but we don't
    // download those assets). Linux just runs the .py script.
#if defined(Q_OS_WIN)
    return "yt-dlp.exe";
#elif defined(Q_OS_MAC)
    return "yt-dlp_macos";
#else
    return "yt-dlp";
#endif
}

QString YoutubeDl::installDir() {
    QString base = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
#if defined(Q_OS_WIN) || defined(Q_OS_MAC)
    return base + "/yt-dlp";
#else
    return base;
#endif
}

QString YoutubeDl::find(bool force) {
    if (!force && !path.isEmpty()) return path;

    // Prefer the downloaded copy. On macOS/Windows that's the extracted
    // onedir bundle; on Linux it's the .py script.
    QString localPath = installDir() + "/" + bundledBinaryName();
    if (QFile::exists(localPath)) {
        QProcess* process = instance(localPath, QStringList() << "--version");
        process->start();
        process->waitForFinished();
        if (process->state() != QProcess::NotRunning) process->kill();
        bool ok = process->exitStatus() == QProcess::NormalExit && process->exitCode() == 0;
        process->deleteLater();
        if (ok) {
            path = localPath;
            return path;
        }
    }

    // Try system-wide yt-dlp installation
    QString globalPath = QStandardPaths::findExecutable("yt-dlp");
    if (!globalPath.isEmpty()) {
        QProcess* process = instance(globalPath, QStringList() << "--version");
        process->start();
        process->waitForFinished();
        if (process->state() != QProcess::NotRunning) process->kill();
        bool ok = process->exitStatus() == QProcess::NormalExit && process->exitCode() == 0;
        process->deleteLater();
        if (ok) {
            path = globalPath;
            return path;
        }
    }

    return "";
}

QProcess* YoutubeDl::instance(QStringList arguments) {
    return instance(find(), arguments);
}

QProcess* YoutubeDl::instance(QString path, QStringList arguments) {
    QProcess *process = new QProcess();

    QString execPath = QCoreApplication::applicationDirPath();
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    QStringList finalArgs;

    #if defined(Q_OS_WIN)
        // yt-dlp.exe is a PyInstaller bundle — spawn it directly, no Python
        // wrapper. execPath stays on PATH so the bundled ffmpeg.exe / deno.exe
        // are reachable when yt-dlp shells out.
        env.insert("PATH", QDir::toNativeSeparators(execPath) + ";" + env.value("PATH"));
        process->setProgram(path);
        finalArgs = arguments;
    #elif defined(Q_OS_MAC)
        // yt-dlp_macos is a PyInstaller bundle. Augment PATH with execPath
        // (bundled ffmpeg / deno) and the usual Homebrew / system bin dirs
        // so the JavaScript runtime (deno / node) is found when the YouTube
        // extractor needs it.
        QStringList pathParts;
        pathParts << execPath
                  << "/opt/homebrew/bin"
                  << "/opt/homebrew/sbin"
                  << "/usr/local/bin"
                  << "/usr/local/sbin"
                  << env.value("PATH");
        env.insert("PATH", pathParts.join(":"));
        process->setProgram(path);
        finalArgs = arguments;
    #else
        // Linux: keep running the .py script through the system Python.
        env.insert("PATH", execPath + ":" + env.value("PATH"));
        process->setProgram(QStandardPaths::findExecutable("python3"));
        finalArgs = QStringList() << path << arguments;
    #endif

    QSettings settings;
    QStringList proxyArguments;
    if (settings.value("UseProxy", false).toBool()) {
        QUrl proxyUrl;

        proxyUrl.setHost(settings.value("ProxyHost", "").toString());
        proxyUrl.setPort(settings.value("ProxyPort", "").toInt());

        if (settings.value("ProxyType", false).toInt() == 0) {
            proxyUrl.setScheme("http");
        } else {
            proxyUrl.setScheme("socks5");
        }
        if (settings.value("ProxyAuthenticationRequired", false).toBool() == true) {
            proxyUrl.setUserName(settings.value("ProxyUsername", "").toString());
            proxyUrl.setPassword(settings.value("ProxyPassword").toString());
        }

        proxyArguments << "--proxy" << proxyUrl.toString();
    }

    QStringList networkArguments;
    if (settings.value("forceIpV4", false).toBool()) {
        networkArguments << "--force-ipv4";
    }

    finalArgs << proxyArguments << networkArguments;
    process->setArguments(finalArgs);
    process->setWorkingDirectory(QDir::tempPath());
    process->setProcessEnvironment(env);

    return process;
}

QString YoutubeDl::getVersion() {
    QProcess* youtubeDl = instance(QStringList("--version"));
    youtubeDl->start();
    youtubeDl->waitForFinished(10000);
    QString version = youtubeDl->readAllStandardOutput() + youtubeDl->readAllStandardError();
    youtubeDl->deleteLater();
    return version.replace("\n", "");
}

QString YoutubeDl::getPythonVersion() {
    // The PyInstaller bundle on macOS/Windows is self-contained, so there's
    // no separately-invocable Python interpreter to interrogate. Only the
    // Linux path still runs through a system python3.
    #if defined(Q_OS_WIN) || defined(Q_OS_MAC)
        return QString();
    #else
        QProcess* python = new QProcess();
        python->setProgram(QStandardPaths::findExecutable("python3"));
        python->setArguments(QStringList("--version"));
        python->start();
        python->waitForFinished(10000);
        QString version = python->readAllStandardOutput() + python->readAllStandardError();
        python->deleteLater();
        return version.replace("\n", "");
    #endif
}

QString YoutubeDl::findPython() {
    #if defined(Q_OS_WIN) || defined(Q_OS_MAC)
        return QString();  // bundled into the PyInstaller binary, no path
    #else
        return QStandardPaths::findExecutable("python3");
    #endif
}
