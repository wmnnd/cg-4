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

#include <QHash>
#include <QMainWindow>
#include <QSignalMapper>
#include <QtXml>
#include <QUrl>
#include "ui_mainwindow.h"
#include "ui_metadata-dialog.h"
#include "clipgrab.h"
#include "video.h"
#include "notifications.h"
#include "download_list_model.h"

class QNetworkAccessManager;
class QListWidgetItem;

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
     QTimer searchTimer;
     QNetworkAccessManager* thumbnailNAM;
     // Items waiting on their thumbnail load — keyed by the reply we're
     // waiting on so the handler can update the right row when the network
     // request finishes (or quietly skip stale replies for cleared items).
     QHash<QObject*, QListWidgetItem*> thumbnailRequests;
     void updateSearch(QString keywords);
     void updateYoutubeDlVersionInfo();
     void requestThumbnail(QListWidgetItem* item, const QString& url);

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
    void handleSearchResultActivated(QListWidgetItem* item);

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
