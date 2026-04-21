import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/interface/sync_resource.dart';
import 'package:simple_live_app/services/db_service.dart';

class HistorySyncResource implements SyncResource<List<History>> {
  @override
  String get fileName => "SimpleLive_histories.json";

  @override
  Future<List<History>> loadLocal() async {
    return DBService.instance.getHistories();
  }

  @override
  List<History>? loadRemote(Archive archive) {
    final file = archive.findFile(fileName);
    if (file == null) return null;
    final jsonData = jsonDecode(utf8.decode(file.content));
    return (jsonData['data'] as List)
        .map((e) => History.fromJson(e))
        .toList();
  }

  @override
  Future<void> saveLocal(List<History> data) async {
    await DBService.instance.historyBox.clear();
    for (var item in data) {
      await DBService.instance.addOrUpdateHistory(item);
    }
  }

  @override
  void saveRemote(Archive archive, List<History> data) {
    final bytes = utf8.encode(jsonEncode({
      'data': data.map((e) => e.toJson()).toList(),
    }));
    archive.addFile(
      ArchiveFile(fileName, bytes.length, bytes),
    );
  }

  @override
  List<History> merge(List<History> local, List<History> remote) {
    final map = {for (var item in local) item.id: item};
    for (var item in remote) {
      if (!map.containsKey(item.id) ||
          item.updateTime.isAfter(map[item.id]!.updateTime)) {
        map[item.id] = item;
      }
    }
    return map.values.toList()
      ..sort((a, b) => b.updateTime.compareTo(a.updateTime));
  }
}
