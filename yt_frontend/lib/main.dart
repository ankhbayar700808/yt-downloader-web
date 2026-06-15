import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:universal_html/html.dart' as html;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'YouTube Playlist Downloader',
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: Colors.red,
        scaffoldBackgroundColor: const Color(0xFF121212),
        cardTheme: const CardTheme(color: Color(0xFF1E1E1E)),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _urlController = TextEditingController();
  bool _isLoading = false;
  String _playlistTitle = '';
  List<dynamic> _playlistVideos = [];
  
  // Сонголтын бүтэц
  final Map<String, Map<String, bool>> _videoSelectionMap = {};
  
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String _progressMessage = '';

  final String _backendUrl = 'http://localhost:5000';

  Future<void> _fetchPlaylist() async {
    final inputUrl = _urlController.text.trim();
    if (inputUrl.isEmpty) {
      _showSnackBar('Юүтүб плэйлист линк оруулна уу!');
      return;
    }

    setState(() {
      _isLoading = true;
      _playlistVideos = [];
      _playlistTitle = '';
      _videoSelectionMap.clear();
    });

    try {
      final encodedUrl = Uri.encodeComponent(inputUrl);
      final response = await http.get(Uri.parse('$_backendUrl?url=$encodedUrl')); // FastAPI /playlist биш үндсэн рүү чиглэсэн бол өөрчилж болно

      // Хэрэв таны бэкэнд /playlist endpoint-той бол доорхыг хэвээр үлдээгээрэй:
      final responsePlaylist = await http.get(Uri.parse('$_backendUrl/playlist?url=$encodedUrl'));

      if (responsePlaylist.statusCode == 200) {
        final data = json.decode(utf8.decode(responsePlaylist.bodyBytes));
        setState(() {
          _playlistTitle = data['playlistTitle'] ?? 'Нэргүй плэйлист';
          _playlistVideos = data['videos'] ?? [];
          
          for (var video in _playlistVideos) {
            final id = video['id'];
            if (id != null) {
              _videoSelectionMap[id] = {'mp3': false, 'mp4': false};
            }
          }
        });
      } else {
        final errorData = json.decode(utf8.decode(responsePlaylist.bodyBytes));
        _showSnackBar('Алдаа: ${errorData['detail'] ?? 'Плэйлист уншиж чадсангүй'}');
      }
    } catch (e) {
      _showSnackBar('Сервертэй холбогдоход алдаа гарлаа.');
    } finally {
      setState(() { _isLoading = false; });
    }
  }

  void _downloadSelectedVideosStream() {
    List<String> mp3Ids = [];
    List<String> mp4Ids = [];

    _videoSelectionMap.forEach((id, formats) {
      if (formats['mp3'] == true) mp3Ids.add(id);
      if (formats['mp4'] == true) mp4Ids.add(id);
    });

    if (mp3Ids.isEmpty && mp4Ids.isEmpty) {
      _showSnackBar('Татах ямар нэгэн дуу эсвэл формат сонгоогүй байна!');
      return;
    }

    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.0;
      _progressMessage = 'Бэкэнд сервертэй холбогдож байна...';
    });

    final String mp3Query = mp3Ids.join(',');
    final String mp4Query = mp4Ids.join(',');

    final eventSourceUrl = '$_backendUrl/download-progress-v2?mp3_ids=$mp3Query&mp4_ids=$mp4Query';
    final html.EventSource eventSource = html.EventSource(eventSourceUrl);

    eventSource.onMessage.listen((html.MessageEvent event) {
      final data = json.decode(event.data);
      
      setState(() {
        _downloadProgress = data['progress'] ?? 0.0;
        _progressMessage = data['message'] ?? '';
      });

      if (data['status'] == 'completed') {
        eventSource.close();
        
        final String fileId = data['file_id'];
        final String finalDownloadUrl = '$_backendUrl/fetch-file/$fileId';
        
        final html.AnchorElement anchor = html.AnchorElement(href: finalDownloadUrl);
        anchor.setAttribute("download", "youtube_bundle.zip");
        anchor.click();

        // 🔥 ШИНЭЧЛЭЛ 1 & 2: Татаж дууссаны дараа бүгдийг UNCHECKED болгох ба Төлвийг шинэчлэх
        setState(() {
          _isDownloading = false;
          _videoSelectionMap.forEach((id, formats) {
            formats['mp3'] = false;
            formats['mp4'] = false;
          });
        });
        
        // Снэкбарыг прогресс баар хаагдсаны дараа үзүүлнэ
        _showSnackBar('🎉 ZIP архив амжилттай бэлэн болж, таталт эхэллээ!');
      }

      if (data['status'] == 'error') {
        eventSource.close();
        setState(() { _isDownloading = false; });
        _showSnackBar(data['message']);
      }
    });

    eventSource.onError.listen((event) {
      eventSource.close();
      setState(() { _isDownloading = false; });
    });
  }

  void _downloadSingleVideo(String videoUrl, String title) {
    final formatParam = _selectedFormatForSingle.toLowerCase();
    final downloadUrl = '$_backendUrl/download-zip?ids=${videoUrl.split('v=')[1]}&format=$formatParam';
    final html.AnchorElement anchor = html.AnchorElement(href: downloadUrl);
    anchor.setAttribute("download", "$title.$formatParam");
    anchor.click();
  }
  
  String _selectedFormatForSingle = 'mp3';

  void _toggleSelectAll(bool? checked) {
    setState(() {
      _videoSelectionMap.forEach((id, formats) {
        formats['mp3'] = checked ?? false;
        formats['mp4'] = checked ?? false;
      });
    });
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.green[800],
        duration: const Duration(seconds: 4),
      )
    );
  }

  String _formatDuration(dynamic seconds) {
    if (seconds == null) return '00:00';
    int sec = seconds is int ? seconds : int.tryParse(seconds.toString()) ?? 0;
    return '${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')}';
  }

  int _getTotalSelectedCount() {
    int count = 0;
    _videoSelectionMap.forEach((id, formats) {
      if (formats['mp3'] == true) count++;
      if (formats['mp4'] == true) count++;
    });
    return count;
  }

  // 🔥 ШИНЭЧЛЭЛ 3: Сонгосон дуунуудын нийт БАГТААМЖИЙГ тооцоолох функц
  String _calculateTotalSize() {
    double totalMB = 0.0;

    for (var video in _playlistVideos) {
      final id = video['id'];
      if (id == null || !_videoSelectionMap.containsKey(id)) continue;

      final formats = _videoSelectionMap[id]!;
      final dynamic durationRaw = video['duration'];
      int durationSeconds = durationRaw is int ? durationRaw : int.tryParse(durationRaw.toString()) ?? 0;
      double durationMinutes = durationSeconds / 60.0;

      // MP3 = ~1MB/минут, MP4 = ~4MB/минут
      if (formats['mp3'] == true) {
        totalMB += (durationMinutes * 1.0);
      }
      if (formats['mp4'] == true) {
        totalMB += (durationMinutes * 4.0);
      }
    }

    if (totalMB == 0) return "0 MB";
    if (totalMB > 1024) {
      return "${(totalMB / 1024).toStringAsFixed(2)} GB";
    }
    return "${totalMB.toStringAsFixed(1)} MB";
  }

  @override
  Widget build(BuildContext context) {
    int totalFilesToDownload = _getTotalSelectedCount();
    String estimatedSize = _calculateTotalSize(); // Багтаамжийг тооцож авах
    
    bool isAllSelected = _videoSelectionMap.isNotEmpty && 
        _videoSelectionMap.values.every((f) => f['mp3'] == true && f['mp4'] == true);

    return Scaffold(
      appBar: AppBar(
        title: const Text('🔴 YouTube Multi-Format Downloader'),
        backgroundColor: Colors.red[900],
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 950),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Оролтын хэсэг
                Card(
                  elevation: 6,
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _urlController,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: 'YouTube Playlist URL паст хийнэ үү',
                              prefixIcon: Icon(Icons.playlist_play, color: Colors.red),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        ElevatedButton.icon(
                          onPressed: _isLoading ? null : _fetchPlaylist,
                          icon: _isLoading 
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.refresh),
                          label: const Text('Плэйлист Уншуулах'),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.red[700], foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 19)),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Прогресс харуулах хэсэг
                if (_isDownloading)
                  Card(
                    color: Colors.blueGrey[900],
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(_progressMessage, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.cyanAccent)),
                              ),
                              Text('${(_downloadProgress * 100).toStringAsFixed(0)}%', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.cyanAccent)),
                            ],
                          ),
                          const SizedBox(height: 12),
                          LinearProgressIndicator(
                            value: _downloadProgress,
                            backgroundColor: Colors.grey[800],
                            color: Colors.cyan,
                            minHeight: 8,
                          ),
                        ],
                      ),
                    ),
                  ),

                // Масс удирдлагын хэсэг
                if (_playlistVideos.isNotEmpty && !_isDownloading)
                  Card(
                    color: Colors.red[950]?.withOpacity(0.15),
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Checkbox(
                                value: isAllSelected, 
                                activeColor: Colors.red, 
                                onChanged: _toggleSelectAll
                              ),
                              const Text('Бүх дууны MP3, MP4-ийг зэрэг сонгох', style: TextStyle(fontWeight: FontWeight.bold)),
                              const SizedBox(width: 12),
                              Text('(Нийт файл: $totalFilesToDownload)', style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
                            ],
                          ),
                          // 🔥 ШИНЭЧЛЭЛТ: Татах товчлуур дээр Нийт тоо болон Багтаамж хамт харагдана
                          ElevatedButton.icon(
                            onPressed: totalFilesToDownload == 0 ? null : _downloadSelectedVideosStream,
                            icon: const Icon(Icons.download_for_offline),
                            label: Text('Багцыг татах ($totalFilesToDownload файл ~ $estimatedSize)'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green[700], 
                              foregroundColor: Colors.white, 
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14)
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Дуунуудын жагсаалт
                Expanded(
                  child: _playlistVideos.isEmpty
                      ? Center(child: _isLoading ? const Text('Юүтүбээс мэдээлэл татаж байна...') : const Text('Одоогоор жагсаалт хоосон байна.', style: TextStyle(color: Colors.grey)))
                      : ListView.builder(
                          itemCount: _playlistVideos.length,
                          itemBuilder: (context, index) {
                            final video = _playlistVideos[index];
                            final id = video['id'] ?? '';
                            final title = video['title'] ?? 'Нэргүй видео';
                            final duration = _formatDuration(video['duration']);
                            
                            final formats = _videoSelectionMap[id] ?? {'mp3': false, 'mp4': false};
                            final bool isMp3Checked = formats['mp3'] ?? false;
                            final bool isMp4Checked = formats['mp4'] ?? false;
                            final bool isMainChecked = isMp3Checked || isMp4Checked;

                            return Card(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 6.0),
                                child: ListTile(
                                  leading: Checkbox(
                                    value: isMainChecked,
                                    activeColor: Colors.red,
                                    onChanged: _isDownloading ? null : (bool? value) {
                                      setState(() {
                                        formats['mp3'] = value ?? false;
                                        formats['mp4'] = value ?? false;
                                      });
                                    },
                                  ),
                                  title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: isMainChecked ? Colors.white : Colors.grey, fontWeight: isMainChecked ? FontWeight.bold : FontWeight.normal)),
                                  subtitle: Text('Хугацаа: $duration', style: const TextStyle(color: Colors.grey)),
                                  
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      // MP3 Checkbox
                                      Row(
                                        children: [
                                          const Text('MP3', style: TextStyle(fontSize: 12, color: Colors.grey)),
                                          Checkbox(
                                            value: isMp3Checked,
                                            activeColor: Colors.red[700],
                                            onChanged: _isDownloading ? null : (bool? value) {
                                              setState(() {
                                                formats['mp3'] = value ?? false;
                                              });
                                            },
                                          ),
                                        ],
                                      ),
                                      const SizedBox(width: 10),
                                      // MP4 Checkbox
                                      Row(
                                        children: [
                                          const Text('MP4', style: TextStyle(fontSize: 12, color: Colors.grey)),
                                          Checkbox(
                                            value: isMp4Checked,
                                            activeColor: Colors.blue[700],
                                            onChanged: _isDownloading ? null : (bool? value) {
                                              setState(() {
                                                formats['mp4'] = value ?? false;
                                              });
                                            },
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}