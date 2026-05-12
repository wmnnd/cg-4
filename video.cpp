/*
    ClipGrab³
    Copyright (C) The ClipGrab Project
    http://clipgrab.de
    feedback [at] clipgrab [dot] de

    This file is part of ClipGrab.
    ClipGrab is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
    
    ClipGrab is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with ClipGrab.  If not, see <http://www.gnu.org/licenses/>.
*/



#include "video.h"

video::video() {
    selectedQuality = -1;
    state = state::empty;

    youtubeDl = nullptr;

    targetConverter = nullptr;
    cachedDownloadSize = 0;
    cachedDownloadProgress = 0;
    audioOnly = false;
    duration = 0;
}

void video::startYoutubeDl(QStringList arguments) {
    if (youtubeDl != nullptr) youtubeDl->deleteLater();

    youtubeDl = YoutubeDl::instance(arguments);
    connect(youtubeDl , QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this, &video::handleProcessFinished);
    connect(youtubeDl , &QProcess::readyRead, this, &video::handleProcessReadyRead);
    youtubeDl->start();
}

void video::fetchPlaylistInfo(QString url) {
    if (state != state::empty) return;
    state = state::fetching;

    this->url = url;

    QStringList arguments;
    arguments << "-J" << url;
    arguments << "--yes-playlist";
    arguments << "--flat-playlist";
    startYoutubeDl(arguments);
}

void video::fetchInfo(QString url) {
    if (state != state::empty) return;
    state = state::fetching;

    // youtube-dl fails on YouTube links that include ?list parameter
    QUrl parsedUrl = QUrl(url);
    if (parsedUrl.host() == "www.youtube.com" && parsedUrl.path() == "/watch") {
        QString v = QUrlQuery(parsedUrl.query()).queryItemValue("v");
        parsedUrl.setQuery("v=" + v);
        url = parsedUrl.toString();
    } else if (parsedUrl.host() == "youtu.be") {
        QString v = parsedUrl.path();
        parsedUrl.setUrl("https://www.youtube.com/watch?v=" + v);
    }

    this->url = url;

    QStringList arguments;
    arguments << "-J";
    arguments << "--no-playlist";
    arguments << url;

    startYoutubeDl(arguments);
}

void video::download() {
    if ((state != state::fetched && state != state::paused && state != state::canceled) || selectedQuality <= -1) return;
    state = state::downloading;

    videoQuality quality = qualities.at(selectedQuality);
    downloadSize = quality.videoFileSize + quality.audioFileSize;

    QStringList arguments;

    arguments << "--newline";
    arguments << "--no-playlist";
    arguments << "--no-mtime";

    QString fileTemplate = QDir::cleanPath(
                QStandardPaths::writableLocation(QStandardPaths::TempLocation) +
                QDir::separator() +
                "/cg-youtube-dl-%(id)s-%(format_id)s.%(ext)s"
    );
    arguments << "-o" << fileTemplate;

    if (quality.audioFormat.isEmpty()) {
        arguments << "-f" << quality.videoFormat;
    } else if (audioOnly) {
        arguments << "-f" << quality.audioFormat;
    } else {
        arguments << "-f" << quality.videoFormat + "+" + quality.audioFormat;
    }

    arguments << url;

    startYoutubeDl(arguments);
}

void video::cancel() {
    if (state != state::downloading && state != state::paused) return;

    state = state::canceling;
    if (youtubeDl != nullptr) youtubeDl->terminate();
}

void video::pause() {
    if (state!= state::downloading) return;

    state = state::pausing;
    if (youtubeDl != nullptr) youtubeDl->terminate();
}

void video::resume() {
    if (state != state::paused) return;

    download();
}

void video::restart() {
    if (state != state::canceled && state != state::error) return;

    download();
}

void video::fromJson(QByteArray data) {
    if (state != state::empty) return;
    handleInfoJson(data);
}

void video::handleInfoJson(QByteArray data) {
    QJsonDocument document = QJsonDocument::fromJson(data);
    if (document.isNull()) {
        state = state::error;
        return;
    }

    QJsonObject json = document.object();
    if (json.empty()) {
        state = state::error;
        return;
    }

    title = json.value("title").toString();
    id = json.value("id").toString();

    if (json.value("_type").toString() == "playlist") {
        QJsonArray playlist = json.value("entries").toArray();
        for (int i = 0; i < playlist.size(); i++) {
            video* video = new class video;
            video->fromJson(QJsonDocument(playlist.at(i).toObject()).toJson());
            playlistVideos << video;
        }

        state = state::fetched;
        return;
    } else if (json.value("_type").toString() == "url") {
        portal = json.value("ie_key").toString().toLower();
        if (portal == "generic") portal = QUrl(this->url).host();

        url = json.value("url").toString();
        if (QUrl(url).scheme().isEmpty() && portal == "youtube") {
            url = "https://www.youtube.com/watch?v=" + url;
        }

        duration = json.value("duration").toInt(0);

        state = state::unfetched;
        return;
    }

    portal = json.value("extractor").toString().toLower();
    if (portal.isEmpty()) portal = json.value("ie_key").toString().toLower();
    else if (portal == "generic") portal = QUrl(this->url).host();

    url = json.value("webpage_url").toString();
    if (url.isEmpty()) url = json.value("url").toString();
    if (QUrl(url).scheme().isEmpty() && portal == "youtube") {
        url = "https://www.youtube.com/watch?v=" + url;
    }

    artist = json.value("artist").toString();
    if (artist.isEmpty()) artist = json.value("user").toString();
    if (artist.isEmpty()) artist = json.value("uploader").toString();

    duration = json.value("duration").toDouble();

    QJsonArray formats = json.value("formats").toArray();
    QList<QJsonObject> videoFormats;
    QList<QJsonObject> audioFormats;
    QStringList acceptedVideoExts = {"mp4"};
    QStringList vcodecPreferences = {"avc1", "av01"};
    if (QSettings().value("UseWebM", false).toBool()) {
        acceptedVideoExts << "webm";
        vcodecPreferences.clear();
    }
    // Always accept all audio formats so language detection sees every
    // available track. YouTube typically only ships per-language audio in
    // opus/webm (m4a itag 140 is the single original-language track), so
    // filtering audio by ext at input would hide the language picker.
    auto languageOf = [](const QJsonObject& format) -> QString {
        // Prefer the top-level "language" field, but fall back to the
        // nested audio_track.id (which yt-dlp populates as a BCP-47-ish
        // code such as "en.4" or "es-419.7"). Different player clients
        // populate one or the other.
        QString lang = format.value("language").toString();
        if (!lang.isEmpty()) return lang;
        QJsonObject audioTrack = format.value("audio_track").toObject();
        QString trackId = audioTrack.value("id").toString();
        if (!trackId.isEmpty()) return trackId.split('.').value(0);
        return audioTrack.value("language").toString();
    };
    auto isOriginalTrack = [](const QJsonObject& format) -> bool {
        if (format.value("format_note").toString().toLower().contains("original")) return true;
        QJsonObject audioTrack = format.value("audio_track").toObject();
        return audioTrack.value("display_name").toString().toLower().contains("original");
    };
    for (int i = 0; i < formats.size(); i++) {
        QJsonObject format = formats.at(i).toObject();
        QString ext = format.value("ext").toString();
        if (format.value("vcodec").toString() == "none") {
            // Annotate with the language we resolved so later code can rely on it.
            format["language"] = languageOf(format);
            audioFormats << format;
        } else if (acceptedVideoExts.contains(ext)) {
            videoFormats << format;
        }
    }

    // Detect the "original" audio language (yt-dlp marks it in format_note
    // and/or audio_track.display_name).
    originalLanguage.clear();
    for (int i = 0; i < audioFormats.length(); i++) {
        if (!isOriginalTrack(audioFormats.at(i))) continue;
        QString language = audioFormats.at(i).value("language").toString();
        if (language.isEmpty()) continue;
        originalLanguage = language;
        qDebug() << "Detected original audio language" << language;
        break;
    }

    {
        // Surface what we resolved so users hitting "Default" / single-language
        // issues can see whether yt-dlp returned per-language tracks at all.
        QStringList summary;
        for (int i = 0; i < audioFormats.size(); i++) {
            QString lang = audioFormats.at(i).value("language").toString();
            summary << QString("%1[%2]").arg(
                audioFormats.at(i).value("format_id").toString(),
                lang.isEmpty() ? QString("-") : lang);
        }
        qDebug() << "Audio formats from yt-dlp:" << summary.join(", ");
    }

    // Sort audio formats by bitrate
    std::sort(audioFormats.begin(), audioFormats.end(), [](QJsonObject a, QJsonObject b) {
        double tbrA = a.value("tbr").toDouble();
        double tbrB = b.value("tbr").toDouble();
        if (tbrA != tbrB) return tbrA > tbrB;

        // Finally use alphabetic ordering of the format string.
        QString formatA = a.value("format").toString();
        QString formatB = b.value("format").toString();
        if (formatA != formatB) return formatA < formatB;

        return false;
    });

    // Sort video formats
    std::sort(videoFormats.begin(), videoFormats.end(), [vcodecPreferences](QJsonObject a, QJsonObject b) {
        int heightA = a.value("height").toInt();
        int heightB = b.value("height").toInt();
        if (heightA != heightB) return heightA > heightB;

        int fpsA = a.value("fps").toInt();
        int fpsB = b.value("fps").toInt();
        if (fpsA != fpsB) return fpsA > fpsB;

        QString extA = a.value("ext").toString();
        QString extB = b.value("ext").toString();
        if (extA != extB) return extA > extB;

        QString vcodecA = a.value("vcodec").toString();
        QString vcodecB = b.value("vcodec").toString();

        bool vcodecAPreferencePos = vcodecPreferences.length();
        bool vcodecBPreferencePos = vcodecPreferences.length();

        for (int i = 0; i < vcodecPreferences.length(); i++) {
            if (vcodecA.startsWith(vcodecPreferences.at(i))) vcodecAPreferencePos = i;
            if (vcodecB.startsWith(vcodecPreferences.at(i))) vcodecBPreferencePos = i;
        }

        // If there is a preferred codec, put it first
        if (vcodecAPreferencePos != vcodecBPreferencePos) return vcodecAPreferencePos < vcodecBPreferencePos;

        // Else use alphabetic ordering
        if (vcodecA != vcodecB) return vcodecA < vcodecB;

        QString acodecA = a.value("acodec").toString();
        QString acodecB = b.value("acodec").toString();
        if (acodecA != acodecB) {
            if (acodecA == "none") return true;
            if (acodecB == "none") return false;
        }

        // Finally use alphabetic ordering of the format string.
        QString formatA = a.value("format").toString();
        QString formatB = b.value("format").toString();
        if (formatA != formatB) return formatA < formatB;

        return false;
    });

    // Remove duplicate video formats (keeping language-specific variants since
    // same resolution may exist for multiple audio languages on combined formats)
    videoFormats.erase(
        std::unique(videoFormats.begin(), videoFormats.end(), [](QJsonObject a, QJsonObject b) {
            int heightA = a.value("height").toInt();
            int heightB = b.value("height").toInt();
            if (heightA != heightB) return false;

            int fpsA = a.value("fps").toInt();
            int fpsB = b.value("fps").toInt();
            if (fpsA != fpsB) return false;

            QString langA = a.value("language").toString();
            QString langB = b.value("language").toString();
            return langA == langB;
        }),
        videoFormats.end()
    );

    // Collect the unique audio languages so the UI can offer a language picker.
    // Also build an audioQualities list (one entry per audio language, picking
    // the highest-bitrate format in that language).
    QStringList audioLanguages;
    for (int i = 0; i < audioFormats.size(); i++) {
        QString lang = audioFormats.at(i).value("language").toString();
        if (!audioLanguages.contains(lang)) {
            audioLanguages << lang;
        }
    }
    audioQualities.clear();
    for (const QString& lang : audioLanguages) {
        // audioFormats is already sorted by bitrate desc, so the first match
        // for each language is the highest quality one.
        for (int i = 0; i < audioFormats.size(); i++) {
            if (audioFormats.at(i).value("language").toString() != lang) continue;
            QJsonObject f = audioFormats.at(i);
            audioQuality aq;
            aq.audioFormat = f.value("format_id").toString();
            aq.audioCodec = f.value("acodec").toString();
            aq.containerName = f.value("ext").toString();
            aq.language = lang;
            aq.audioFileSize = f.value("filesize").toInt();
            aq.bitrate = f.value("tbr").toDouble();
            aq.name = QString::number(aq.bitrate) + " kbps";
            audioQualities << aq;
            break;
        }
    }

    for (int i = 0; i < videoFormats.size(); i ++) {
        QJsonObject videoFormat = videoFormats.at(i);
        int height = videoFormat.value("height").toInt();
        QRegularExpression heightExp("^(\\d+)p");
        QRegularExpressionMatch match = heightExp.match(videoFormat.value("format_note").toString());
        if (match.hasMatch()) height = match.captured(1).toInt();
        int fps = videoFormat.value("fps").toInt();

        QString name = QString::number(height) + "p";
        if (name == "0p") name = tr("unknown");
        else if (fps >= 59) name.append("60");

        if (height >= 4000) {
            name.append(" (8K)");
        } else if (height >= 2000) {
            name.append(" (4K)");
        } else if (height >= 700) {
            name.append(" (HD)");
        }

        if (videoFormat.value("ext").toString() == "webm") {
            name.append(" WebM");
        }

        QString videoLanguage = videoFormat.value("language").toString();

        QStringList compatibleAudioExts = {"aac", "m4a", "mp4"};
        if (videoFormat.value("ext") == "webm") {
             compatibleAudioExts.clear();
             compatibleAudioExts << "webm" << "ogg" << "opus";
        }

        // Generate one quality per available audio language (or one with no
        // audio if there are no audio formats). If the video format itself
        // declares a language, only pair it with matching audio.
        QStringList qualityLanguages;
        if (audioLanguages.isEmpty()) {
            qualityLanguages << QString();
        } else {
            for (const QString& lang : audioLanguages) {
                if (!videoLanguage.isEmpty() && videoLanguage != lang) continue;
                qualityLanguages << lang;
            }
            // If the video declares a language but no matching audio exists,
            // fall back to pairing without language constraint so the user
            // still sees the resolution.
            if (qualityLanguages.isEmpty()) qualityLanguages << QString();
        }

        for (const QString& qualityLanguage : qualityLanguages) {
            videoQuality quality(name, videoFormat.value("format_id").toString());
            quality.resolution = height;
            quality.videoFileSize = videoFormat.value("filesize").toInt();
            quality.audioFileSize = 0;
            quality.containerName = videoFormat.value("ext").toString();
            quality.language = qualityLanguage;

            // Find audio for this language: prefer same-container ext for
            // a clean remux, but fall back to any audio in that language
            // (yt-dlp + ffmpeg will mux/transcode as needed). This matters
            // for YouTube where non-original languages typically only exist
            // in opus, even when the chosen video is mp4.
            QList<QJsonObject> sameContainerAudio;
            QList<QJsonObject> sameLanguageAudio;
            for (int j = 0; j < audioFormats.size(); j++) {
                QJsonObject af = audioFormats.at(j);
                if (af.value("language").toString() != qualityLanguage) continue;
                sameLanguageAudio << af;
                if (compatibleAudioExts.contains(af.value("ext").toString())) {
                    sameContainerAudio << af;
                }
            }
            QList<QJsonObject> compatibleAudioFormats =
                sameContainerAudio.isEmpty() ? sameLanguageAudio : sameContainerAudio;

            if (videoFormat.value("acodec") == "none" && compatibleAudioFormats.size() > 0) {
                int audioIndex = (compatibleAudioFormats.size() -1) * i / qMax(1, videoFormats.size());
                quality.audioFormat = compatibleAudioFormats.at(audioIndex).value("format_id").toString();
                quality.audioFileSize = compatibleAudioFormats.at(audioIndex).value("filesize").toInt();
            }

            qualities << quality;
        }
    }

    state = state::fetched;
}

void video::handleDownloadInfo(QString line) {
    qDebug() << line;
    QRegularExpression re;
    QRegularExpressionMatch match;

    re.setPattern("^\\[download\\] Destination: (.+)");
    match = re.match(line);
    if (!match.captured(1).isNull()) {
        QString filename = match.captured(1);
        if (!downloadFilenames.contains(filename)) {
            downloadFilenames << match.captured(1);
            downloadSizeEstimates << 0;
        }
        return;
    }

    re.setPattern("^\\[download\\] (.+?) has already been downloaded( and merged)?");
    match = re.match(line);
    if (!match.captured(1).isNull()) {
        finalDownloadFilename = match.captured(1);
        return;
    }
    re.setPattern("^\\[ffmpeg|Merger\\] Merging formats into \"([^\"]+)\"");
    match = re.match(line);
    if (!match.captured(1).isNull()) {
        finalDownloadFilename = match.captured(1);
        return;
    }

    re.setPattern("^\\[download\\]\\s+(\\d+\\.\\d)%\\s+of\\s+~?\\s*(\\d+\\.\\d+)(T|G|M|K)iB");
    match = re.match(line);
    if (match.hasMatch() && !downloadFilenames.isEmpty() && !downloadSizeEstimates.isEmpty()) {
        qint64 downloadProgress = 0;
        for (int i = 0; i < downloadFilenames.size(); i++) {
            downloadProgress += QFileInfo(downloadFilenames.at(i)).size();
            downloadProgress += QFileInfo(downloadFilenames.at(i) + ".part").size();
        }

        QStringList prefixes {"K", "M", "G", "T"};
        qint64 downloadSizeEstimate = match.captured(2).toFloat() * pow(1024, 1 + prefixes.indexOf(match.captured(3)));

        qint64 previousDownloadSizeEstimate = downloadSizeEstimates.last();
        bool downloadSizeChangedSignificantly = downloadSize == 0 || (downloadSizeEstimate > previousDownloadSizeEstimate * 1.1) || (previousDownloadSizeEstimate < downloadSize * 0.9);

        if (downloadProgress > 0 && !downloadSizeChangedSignificantly) {
            cachedDownloadProgress = downloadProgress;
            emit downloadProgressChanged(cachedDownloadSize, downloadProgress);
        } else if (downloadProgress > 0) {
            downloadSizeEstimates.replace(downloadSizeEstimates.size() - 1, downloadSizeEstimate);

            qint64 totalDownloadSizeEstimate = 0;
            for (int i = 0; i < downloadSizeEstimates.size(); i++) {
                totalDownloadSizeEstimate += downloadSizeEstimates.at(i);
            }

            if (totalDownloadSizeEstimate > 0) {
                cachedDownloadSize = totalDownloadSizeEstimate;
                cachedDownloadProgress = downloadProgress;
                emit downloadProgressChanged(totalDownloadSizeEstimate, downloadProgress);
            }
        }
    }

    re.setPattern("ERROR:\\s+(.*)");
    match = re.match(line);
    if (match.hasMatch()) {
        qDebug() << "ERROR!" << match.captured(1);
        state = state::error;
        emit stateChanged();
        youtubeDl->kill();
    }
}

bool video::setQuality(int index) {
    if (index < 0 || index >= qualities.size()) return false;

    selectedQuality = index;
    return true;
}


void video::setTargetFilename(QString filename) {
    this->targetFilename = filename;
}

QString video::getSafeFilename() {
    return title.replace(QRegularExpression("#|%|&|\\{|\\}|\\\\|<|>|\\*|\\?|/|\\$|!|'|\"|:|@|\\+|`|\\||=|"), "");
}

void video::setConverter(converter* targetConverter, int targetConverterMode) {
    this->targetConverter = targetConverter->createNewInstance();
    this->targetConverterMode = targetConverterMode;
    this->audioOnly = targetConverter->isAudioOnly(targetConverterMode);

    connect(this->targetConverter, &converter::conversionFinished, this, &video::handleConversionFinished);
    connect(this->targetConverter, &converter::error, this, &video::handleConversionError);
}

QString video::getTitle() {
    return title;
}

QString video::getArtist() {
    return artist;
}

void video::setMetaTitle(QString title) {
    metaTitle = title;
}

void video::setMetaArtist(QString artist) {
    metaArtist = artist;
}

QString video::getThumbnail() {
    if (portal == "youtube") {
        return "https://i.ytimg.com/vi/" + id + "/hqdefault.jpg";
    }
    return "";
}

qint64 video::getDuration() {
    return duration;
}

QString video::getUrl() {
    return url;
}

QList<videoQuality> video::getQualities() {
    return qualities;
}

QList<audioQuality> video::getAudioQualities() {
    return audioQualities;
}

QStringList video::getLanguages() {
    QStringList languages;
    for (int i = 0; i < qualities.size(); i++) {
        const QString& lang = qualities.at(i).language;
        if (!languages.contains(lang)) languages << lang;
    }
    for (int i = 0; i < audioQualities.size(); i++) {
        const QString& lang = audioQualities.at(i).language;
        if (!languages.contains(lang)) languages << lang;
    }
    // If the only "language" present is the empty string, there is no
    // language info and the UI should hide the language picker.
    if (languages.size() == 1 && languages.first().isEmpty()) {
        return QStringList();
    }
    return languages;
}

QString video::getOriginalLanguage() {
    return originalLanguage;
}

QString video::getSelectedQualityName() {
    if (selectedQuality == -1) return "";

    return qualities.at(selectedQuality).name;
}

QString video::getPortalName() {
    if (portal == "youtube") return "YouTube";
    return portal;
}

qint64 video::getDownloadSize() {
    if (cachedDownloadSize < cachedDownloadProgress) return cachedDownloadProgress;
    return cachedDownloadSize;
}

qint64 video::getDownloadProgress() {
    return cachedDownloadProgress;
}

QString video::getTargetFormatName() {
    if (targetConverter == nullptr) return "";
    return targetConverter->getModes().at(targetConverterMode);
}

QList<video*> video::getPlaylistVideos() {
    return playlistVideos;
}

void video::handleProcessFinished(int /*exitCode*/, QProcess::ExitStatus exitStatus) {
    qDebug() << youtubeDl->readAllStandardError();
    switch (state) {
    case state::fetching:
        if (exitStatus == QProcess::ExitStatus::NormalExit) {
            handleInfoJson(youtubeDl->readAllStandardOutput());
            youtubeDl->close();

            if (qualities.length() > 0) {
                qDebug() << "Discovered video: " << title;
                state = state::fetched;
            } else {
                state = state::error;
            }
        } else {
            state = state::error;
        }
        emit stateChanged();
        break;
    case state::downloading:
        if (exitStatus == QProcess::ExitStatus::NormalExit) {

            if (finalDownloadFilename.isEmpty() && !downloadFilenames.empty()) finalDownloadFilename = downloadFilenames.last();
            if (finalDownloadFilename.isEmpty()) {
                state = state::error;
                emit stateChanged();
                return;
            }

            state = state::converting;
            QFile* file = new QFile();
            file->setFileName(finalDownloadFilename);
            targetConverter->startConversion(file, targetFilename, qualities.at(selectedQuality).containerName, metaTitle, metaArtist, targetConverterMode);
        } else {
            state = state::error;
        }
        emit stateChanged();
        break;
    case state::pausing:
        state = state::paused;
        emit stateChanged();
        return;
    case state::canceling:
        removeTempFiles();
        state = state::canceled;
        emit stateChanged();
        return;
    default:
        break;
    }
}

void video::handleProcessReadyRead() {
    switch (state) {
    case state::fetching:
       // data is read all at once when process finishes
       break;
     case state::downloading:
        while (youtubeDl->canReadLine()) {
            handleDownloadInfo(QString::fromLocal8Bit(youtubeDl->readLine()));
        }
        break;
     default:
        break;
    }
}

void video::handleConversionFinished() {
    removeTempFiles();
    finalFilename = targetConverter->target;
    state = state::finished;
    emit stateChanged();
}

void video::handleConversionError(QString /*error*/) {
    state = state::error;
    emit stateChanged();
}

void video::removeTempFiles() {
    for (int i = 0; i < downloadFilenames.size(); i++) {
        QFile::remove(downloadFilenames.at(i));
        QFile::remove(downloadFilenames.at(i) + ".part");
    }
    QFile::remove(finalDownloadFilename);
}
