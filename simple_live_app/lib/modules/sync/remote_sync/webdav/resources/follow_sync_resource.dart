import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:fractional_indexing_dart/fractional_indexing_dart.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/utils/duration_2_str_utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/interface/sync_resource.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

class FollowBundle {
  final List<FollowUser> follows;
  final List<FollowUserTag> tags;

  FollowBundle({
    List<FollowUser>? follows,
    List<FollowUserTag>? tags,
  })  : follows = follows ?? [],
        tags = tags ?? [];
}

class FollowSyncResource implements SyncResource<FollowBundle> {
  @override
  String get fileName => "SimpleLive_follows.json";

  String get tagFileName => "SimpleLive_Tags.json";

  @override
  Future<FollowBundle> loadLocal() async {
    var followList = DBService.instance.getFollowList();
    var tagList = DBService.instance.getFollowTagList();
    return FollowBundle(
      follows: followList,
      tags: tagList,
    );
  }

  @override
  FollowBundle? loadRemote(Archive archive) {
    final followFile = archive.findFile(fileName);
    final tagFile = archive.findFile(tagFileName);
    if (followFile == null || tagFile == null) return null;

    final followJsonData = jsonDecode(utf8.decode(followFile.content));
    var followRemoteList = (followJsonData['data'] as List)
        .map((e) => FollowUser.fromJson(e))
        .toList();
    final tagJsonData = jsonDecode(utf8.decode(tagFile.content));
    var tagRemoteList = (tagJsonData['data'] as List)
        .map((e) => FollowUserTag.fromJson(e))
        .toList();
    return FollowBundle(
      follows: followRemoteList,
      tags: tagRemoteList,
    );
  }

  @override
  Future<void> saveLocal(FollowBundle data) async {
    await DBService.instance.followBox.clear();
    for (final item in data.follows) {
      await DBService.instance.followBox.put(item.id, item);
    }
    await DBService.instance.tagBox.clear();
    for (final tag in data.tags) {
      await DBService.instance.tagBox.put(tag.id, tag);
    }
    EventBus.instance.emit(Constant.kUpdateFollow, 0);
  }

  @override
  void saveRemote(Archive archive, FollowBundle data) {
    final followBytes = utf8.encode(jsonEncode({
      'data': data.follows.map((e) => e.toJson()).toList(),
    }));

    archive.addFile(
      ArchiveFile(
        fileName,
        followBytes.length,
        followBytes,
      ),
    );

    final tagBytes = utf8.encode(jsonEncode({
      'data': data.tags.map((e) => e.toJson()).toList(),
    }));

    archive.addFile(
      ArchiveFile(
        tagFileName,
        tagBytes.length,
        tagBytes,
      ),
    );
  }

  @override
  FollowBundle merge(
    FollowBundle local,
    FollowBundle remote,
  ) {
    DateTime curLast = DateTime.fromMillisecondsSinceEpoch(
      LocalStorageService.instance.getValue(
        LocalStorageService.kWebDAVLastRecoverTime,
        DateTime(2026, 1, 1).millisecondsSinceEpoch,
      ),
    );
    var resFollows = _mergeFollowList(
        localList: local.follows, remoteList: remote.follows, curLast: curLast);

    // tags after merge, logic from data_check
    final Map<String, List<String>> tagMap = {
      for (var tag in local.tags) tag.tag: <String>[],
    };

    for (var follow in resFollows) {
      if (follow.tag != "全部") {
        tagMap.putIfAbsent(follow.tag, () => <String>[]).add(follow.id);
      }
    }
    final resTags = <FollowUserTag>[];
    ;
    String? lastKey;
    for (var entry in tagMap.entries) {
      lastKey = FractionalIndexing.generateKeyBetween(lastKey, null);
      final followUserTag = FollowUserTag(
        id: lastKey,
        tag: entry.key,
        userId: entry.value,
      );
      resTags.add(followUserTag);
    }
    return FollowBundle(follows: resFollows, tags: resTags);
  }


  // sync-double
  // database op-log maybe better
  // follow: cur! and webdav! -> keep;
  // follow: cur! and webdav? -> cur_item.add_time>cur_last->keep; else->remove;
  // follow: cur? and webdav! -> remote.item.add_time>cur_last->keep; else->remove
  //
  // follow_watchDuration = webdav_watchDuration += syncDuration
  // syncDuration = 0
  List<FollowUser> _mergeFollowList({
    required List<FollowUser> localList,
    required List<FollowUser> remoteList,
    required DateTime curLast,
  }) {
    final Map<String, FollowUser> result = {};
    final localMap = {for (var item in localList) item.id: item};
    final remoteMap = {for (var item in remoteList) item.id: item};

    for (var localItem in localList) {
      var remoteItem = remoteMap[localItem.id];
      if (remoteItem != null || localItem.addTime.isAfter(curLast)) {
        // temp in v10808
        // after v10810:  remoteItem?.watchDurationSec ?? 0 instead
        localItem.watchDurationSec =
            (remoteItem?.watchDuration ?? "00:00:00").toDuration().inSeconds +
                localItem.syncDuration;
        localItem.watchDuration =
            Duration(seconds: localItem.watchDurationSec).toHMSString();
        localItem.syncDuration = 0;
        result[localItem.id] = localItem;
      }
    }

    for (var remoteItem in remoteList) {
      if (!localMap.containsKey(remoteItem.id)) {
        // cur? and webdav!
        if (remoteItem.addTime.isAfter(curLast)) {
          result[remoteItem.id] = remoteItem;
        }
      }
    }
    return result.values.toList();
  }
}
