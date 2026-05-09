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



#ifndef MAINWINDOW_H
#define MAINWINDOW_H

#include <QMainWindow>
#include <QSignalMapper>
#include <QtXml>
#include <QUrl>
#include <QUrlQuery>
#include <QWebEngineView>
#include <QWebEnginePage>
#include <QWebEngineProfile>
#include <QWebEngineSettings>
#include <QWebEngineUrlRequestInterceptor>
#include <QWebEngineUrlRequestInfo>
#include <QFontDatabase>
#include <QRegularExpression>
#include "ui_mainwindow.h"
#include "ui_metadata-dialog.h"
#include "clipgrab.h"
#include "video.h"
#include "notifications.h"
#include "download_list_model.h"


class SearchWebEngineUrlRequestInterceptor : public QWebEngineUrlRequestInterceptor
{
    Q_OBJECT
public:
    using QWebEngineUrlRequestInterceptor::QWebEngineUrlRequestInterceptor;

    void interceptRequest(QWebEngineUrlRequestInfo &info) override {
        if (info.requestUrl().toString().startsWith("https://m.youtube.com/watch?")) {
            info.block(true);
            QUrl url;
            url.setScheme("https");
            url.setHost("www.youtube.com");
            url.setPath("/watch");
            url.setQuery("v=" + QUrlQuery(info.requestUrl().query()).queryItemValue("v"));
            emit intercepted(url);
        }
    }

signals:
        void intercepted(const QUrl & url);
};

class SearchWebEnginePage : public QWebEnginePage
{
    Q_OBJECT
public:
    SearchWebEnginePage(QWebEngineProfile* profile, QObject* parent = nullptr) :  QWebEnginePage(profile, parent)
    {
        this->setAudioMuted(true);
        // Parent the interceptor to the profile so its lifetime matches the
        // profile that holds a pointer to it (avoids dangling pointer in profile).
        SearchWebEngineUrlRequestInterceptor* interceptor = new SearchWebEngineUrlRequestInterceptor(profile);
        this->profile()->setUrlRequestInterceptor(interceptor);
        connect(interceptor, &SearchWebEngineUrlRequestInterceptor::intercepted, this, &SearchWebEnginePage::handleInterceptedUrl);
    }


    bool acceptNavigationRequest(const QUrl & url, QWebEnginePage::NavigationType type, bool isMainFrame) override
    {
        if (!isMainFrame) return true;

        if (type == QWebEnginePage::NavigationTypeTyped)
        {
            QRegularExpression watchRe("https://(www|m)\\.youtube.com/watch");
            if (watchRe.match(url.toString()).hasMatch())
            {
                emit linkClicked(url);
                return false;
            }
            return true;
        }
        if (type == QWebEnginePage::NavigationTypeLinkClicked)
        {
            QRegularExpression hostRe("https://(www|m)\\.youtube.com");
            if (hostRe.match(url.toString()).hasMatch())
            {
                emit linkClicked(url);
            }
        }
        return false;
    }
protected:
    void javaScriptConsoleMessage(QWebEnginePage::JavaScriptConsoleMessageLevel /*level*/, const QString & /*message*/, int /*lineNumber*/, const QString & /*sourceID*/) override {
        //Don't log anything
    }
public slots:
    void handleInterceptedUrl(const QUrl & url) {
        emit linkIntercepted(url);
    }
signals:
    void linkClicked(const QUrl & url);
    void linkIntercepted(const QUrl & url);
};


class MainWindow : public QMainWindow
{
    Q_OBJECT

public:
    MainWindow(ClipGrab* cg, QWidget *parent = nullptr, Qt::WindowFlags flags = Qt::WindowFlags());
    ~MainWindow();
    void init();

    ClipGrab* cg;

public slots:
    void startDownload();
    void compatibleUrlFoundInClipBoard(QString url);
    void targetFileSelected(video* video, QString target);
    void searchTimerTimeout();

private:
    Ui::MainWindowClass ui;
     QSignalMapper *changeTabMapper;
     QSignalMapper *downloadMapper;
     Ui::MetadataDialog mdui;
     QDialog* metadataDialog;
     QSystemTrayIcon systemTrayIcon;
     void disableDownloadUi(bool disable=true);
     void disableDownloadTreeButtons(bool disable=true);
     void closeEvent(QCloseEvent* event);
     void timerEvent(QTimerEvent*);
     void changeEvent(QEvent *);
     void dragEnterEvent(QDragEnterEvent *event);
     void dropEvent(QDropEvent *event);
     bool updatingComboQuality;
     SearchWebEnginePage* searchPage;
     QTimer searchTimer;
     void updateSearch(QString keywords);
     void updateYoutubeDlVersionInfo();

private slots:
    void handleCurrentVideoStateChanged(video*);

    void on_mainTab_currentChanged(int index);
    void on_downloadComboFormat_currentIndexChanged(int index);
    void on_searchLineEdit_textChanged(QString );
    void on_settingsUseMetadata_stateChanged(int );
    void on_label_linkActivated(QString link);
    void on_downloadLineEdit_returnPressed();
    void on_settingsMinimizeToTray_stateChanged(int );
    void on_downloadPause_clicked();
    void on_settingsRemoveFinishedDownloads_stateChanged(int );
    void handle_downloadTree_currentChanged(const QModelIndex &current, const QModelIndex &previous);
    void systemTrayMessageClicked();
    void systemTrayIconActivated(QSystemTrayIcon::ActivationReason);
    void on_downloadOpen_clicked();
    void on_settingsSaveLastPath_stateChanged(int );
    void on_downloadCancel_clicked();
    void on_settingsBrowseTargetPath_clicked();
    void on_settingsSavedPath_textChanged(QString );
    void on_settingsNeverAskForPath_stateChanged(int);

    void settingsClipboard_toggled(bool);
    void settingsNotifications_toggled(bool);
    void settingsProxyChanged();
    void handleSearchResults(video*);
    void handleSearchResultClicked(const QUrl & url);

    void handleFinishedConversion(video*);
    void on_settingsLanguage_currentIndexChanged(int index);
    void on_buttonDonate_clicked();
    void on_settingsUseWebM_toggled(bool checked);
    void on_settingsIgnoreSSLErrors_toggled(bool checked);
    void on_downloadTree_customContextMenuRequested(const QPoint &pos);
    void on_settingsRememberLogins_toggled(bool checked);
    void on_settingsRememberVideoQuality_toggled(bool checked);
    void on_downloadComboQuality_currentIndexChanged(int index);
    void on_downloadTree_doubleClicked(const QModelIndex &index);
    void on_settingsForceIpV4_toggled(bool checked);
};

#endif // MAINWINDOW_H
