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
      title: 'AB Media Downloader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
        primaryColor: const Color(0xFF0A2A92),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0A2A92),
          secondary: const Color(0xFF5992C6),
          surface: Colors.white,
        ),
        cardTheme: CardTheme(
          color: Colors.white,
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          shadowColor: Colors.black.withOpacity(0.05),
        ),
        checkboxTheme: CheckboxThemeData(
          fillColor: WidgetStateProperty.resolveWith<Color?>((states) {
            if (states.contains(WidgetState.selected)) return const Color(0xFF0A2A92);
            return null;
          }),
        ),
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
  bool _isSearchMode = false;

  final Map<String, Map<String, bool>> _videoSelectionMap = {};
  
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String _progressMessage = '';

  final String _backendUrl = 'http://localhost:5000';

  // 🎵 АУДИО ТОГЛУУЛАГЧИЙН ТӨЛӨВҮҮД
  html.AudioElement? _audioPlayer;
  bool _isPlaying = false;
  String _currentPlayingTitle = '';
  String _currentPlayingThumbnail = '';
  bool _isAudioLoading = false;
  int _currentPlayingIndex = -1;

  @override
  void initState() {
    super.initState();
    
    _urlController.addListener(() {
      final text = _urlController.text.trim();
      final isLink = text.startsWith('http://') || text.startsWith('https://') || text.contains('youtube.com') || text.contains('youtu.be');
      setState(() {
        _isSearchMode = text.isNotEmpty && !isLink;
      });
    });

    _audioPlayer = html.AudioElement();
    _audioPlayer?.onPlay.listen((_) => setState(() => _isPlaying = true));
    _audioPlayer?.onPause.listen((_) => setState(() => _isPlaying = false));
    
    _audioPlayer?.onEnded.listen((_) {
      _playNext();
    });
  }

  @override
  void dispose() {
    _audioPlayer?.pause();
    _audioPlayer = null;
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _playAudio(int index) async {
    if (index < 0 || index >= _playlistVideos.length) return;

    final video = _playlistVideos[index];
    final String videoId = video['id'] ?? '';
    final String title = video['title'] ?? 'Нэргүй видео';
    final String thumbnail = video['thumbnail'] ?? '';

    if (_currentPlayingIndex == index && _audioPlayer != null) {
      if (_isPlaying) {
        _audioPlayer!.pause();
      } else {
        _audioPlayer!.play();
      }
      return;
    }

    setState(() {
      _isAudioLoading = true;
      _currentPlayingIndex = index;
      _currentPlayingTitle = title;
      _currentPlayingThumbnail = thumbnail;
    });

    try {
      final response = await http.get(Uri.parse('$_backendUrl/audio-stream?video_id=$videoId'));
      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        final String streamUrl = data['streamUrl'];
        
        _audioPlayer?.src = streamUrl;
        _audioPlayer?.load();
        _audioPlayer?.play();
      } else {
        _showSnackBar('Дууны урсгалыг ачаалахад алдаа гарлаа.');
      }
    } catch (e) {
      _showSnackBar('Бэкэнд сэрвэртэй холбогдож чадсангүй.');
    } finally {
      setState(() { _isAudioLoading = false; });
    }
  }

  void _playNext() {
    if (_playlistVideos.isEmpty) return;
    int nextIndex = _currentPlayingIndex + 1;
    if (nextIndex >= _playlistVideos.length) {
      nextIndex = 0;
    }
    _playAudio(nextIndex);
  }

  void _playPrevious() {
    if (_playlistVideos.isEmpty) return;
    int prevIndex = _currentPlayingIndex - 1;
    if (prevIndex < 0) {
      prevIndex = _playlistVideos.length - 1;
    }
    _playAudio(prevIndex);
  }

  Future<void> _fetchData() async {
    final inputText = _urlController.text.trim();
    if (inputText.isEmpty) {
      _showSnackBar('Юүтүб линк эсвэл хайх үг оруулна уу!');
      return;
    }

    setState(() {
      _isLoading = true;
      _playlistVideos = [];
      _playlistTitle = '';
      _videoSelectionMap.clear();
      _currentPlayingIndex = -1;
      _currentPlayingTitle = '';
    });

    try {
      final encodedText = Uri.encodeComponent(inputText);
      final endpoint = _isSearchMode ? 'search?q=$encodedText' : 'playlist?url=$encodedText';
      
      final response = await http.get(Uri.parse('$_backendUrl/$endpoint'));

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        setState(() {
          _playlistTitle = data['playlistTitle'] ?? 'Илэрцүүд';
          _playlistVideos = data['videos'] ?? [];
          
          for (var video in _playlistVideos) {
            final id = video['id'];
            if (id != null) {
              _videoSelectionMap[id] = {'mp3': false, 'mp4': false};
            }
          }
        });
      } else {
        final errorData = json.decode(utf8.decode(response.bodyBytes));
        _showSnackBar('Алдаа: ${errorData['detail'] ?? 'Мэдээлэл олдохгүй байна'}');
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
      _showSnackBar('Татах ямар нэгэн дуу сонгоогүй байна!');
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

        setState(() {
          _isDownloading = false;
          _videoSelectionMap.forEach((id, formats) {
            formats['mp3'] = false;
            formats['mp4'] = false;
          });
        });
        
        _showSnackBar('🎉 Багц файл амжилттай татагдлаа!');
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
        content: Text(message, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        backgroundColor: const Color(0xFF0A2A92),
        duration: const Duration(seconds: 3),
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

  String _calculateTotalSize() {
    double totalMB = 0.0;
    for (var video in _playlistVideos) {
      final id = video['id'];
      if (id == null || !_videoSelectionMap.containsKey(id)) continue;

      final formats = _videoSelectionMap[id]!;
      final dynamic durationRaw = video['duration'];
      int durationSeconds = durationRaw is int ? durationRaw : int.tryParse(durationRaw.toString()) ?? 0;
      double durationMinutes = durationSeconds / 60.0;

      if (formats['mp3'] == true) totalMB += (durationMinutes * 1.0);
      if (formats['mp4'] == true) totalMB += (durationMinutes * 4.0);
    }

    if (totalMB == 0) return "0 MB";
    if (totalMB > 1024) return "${(totalMB / 1024).toStringAsFixed(2)} GB";
    return "${totalMB.toStringAsFixed(1)} MB";
  }

  @override
  Widget build(BuildContext context) {
    int totalFilesToDownload = _getTotalSelectedCount();
    String estimatedSize = _calculateTotalSize();
    
    bool isAllSelected = _videoSelectionMap.isNotEmpty && 
        _videoSelectionMap.values.every((f) => f['mp3'] == true && f['mp4'] == true);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A2A92),
        elevation: 0,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'ab-logo.png',
                height: 36,
                width: 36,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  return const Icon(Icons.play_circle_fill, color: Colors.white, size: 36);
                },
              ),
            ),
            const SizedBox(width: 12),
            RichText(
              text: const TextSpan(
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                children: [
                  TextSpan(text: 'AB ', style: TextStyle(color: Color(0xFF5992C6))),
                  TextSpan(text: 'Media Downloader', style: TextStyle(color: Colors.white)),
                ],
              ),
            ),
          ],
        ),
        centerTitle: true,
      ),
      
      // `bottomNavigationBar`-ийг бүрэн устгав. Тоглуулагчийг body-ийн жагсаалт дотор байрлуулсан.
      body: Padding(
        padding: const EdgeInsets.fromLTRB(24.0, 24.0, 24.0, 16.0),
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 950),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 🔍 Хайлтын хэсэг
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _urlController,
                            onSubmitted: (_) => _isLoading ? null : _fetchData(),
                            style: const TextStyle(color: Color(0xFF1A202C)),
                            decoration: InputDecoration(
                              border: const OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE2E8F0))),
                              enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE2E8F0))),
                              focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF0A2A92), width: 1.5)),
                              labelText: _isSearchMode ? 'Юүтүбээс хайх үг (Эхний 50 илэрц)...' : 'YouTube Playlist URL эсвэл хайх үг...',
                              labelStyle: TextStyle(color: Colors.grey[600]),
                              prefixIcon: Icon(_isSearchMode ? Icons.search : Icons.playlist_play, color: const Color(0xFF5992C6)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        ElevatedButton.icon(
                          onPressed: _isLoading ? null : _fetchData,
                          icon: _isLoading 
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : Icon(_isSearchMode ? Icons.search : Icons.cloud_download),
                          label: Text(_isSearchMode ? 'Шууд Хайх' : 'Уншуулах'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _isSearchMode ? const Color(0xFF5992C6) : const Color(0xFF0A2A92), 
                            foregroundColor: Colors.white, 
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 19),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Прогресс бар
                if (_isDownloading)
                  Card(
                    color: const Color(0xFFEDF2F7),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(child: Text(_progressMessage, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0A2A92)))),
                              Text('${(_downloadProgress * 100).toStringAsFixed(0)}%', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0A2A92))),
                            ],
                          ),
                          const SizedBox(height: 12),
                          LinearProgressIndicator(value: _downloadProgress, backgroundColor: Colors.grey[300], color: const Color(0xFF5992C6), minHeight: 6),
                        ],
                      ),
                    ),
                  ),

                // Сонгох хэсэг
                if (_playlistVideos.isNotEmpty && !_isDownloading) ...[
                  Padding(
                    padding: const EdgeInsets.only(left: 8.0, bottom: 8.0),
                    child: Text(_playlistTitle, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF1A202C))),
                  ),
                  Card(
                    color: const Color(0xFFEBF8FF),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Checkbox(value: isAllSelected, onChanged: _toggleSelectAll),
                              const Text('Бүгдийг сонгох', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF2B6CB0))),
                              const SizedBox(width: 8),
                              Text('(Нийт файл: $totalFilesToDownload)', style: TextStyle(color: Colors.grey[600], fontWeight: FontWeight.bold, fontSize: 13)),
                            ],
                          ),
                          ElevatedButton.icon(
                            onPressed: totalFilesToDownload == 0 ? null : _downloadSelectedVideosStream,
                            icon: const Icon(Icons.download_for_offline),
                            label: Text('Багцыг татах ($totalFilesToDownload файл ~ $estimatedSize)'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF2F855A), 
                              foregroundColor: Colors.white, 
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],

                // Жагсаалт харуулах хэсэг
                Expanded(
                  child: _playlistVideos.isEmpty
                      ? Center(child: _isLoading ? const Text('Юүтүбээс мэдээлэл шүүж байна...', style: TextStyle(color: Colors.grey)) : const Text('Юүтүб линк оруулах эсвэл хайх үгээ бичээд Enter дарна уу.', style: TextStyle(color: Colors.grey)))
                      : ListView.builder(
                          itemCount: _playlistVideos.length,
                          itemBuilder: (context, index) {
                            final video = _playlistVideos[index];
                            final id = video['id'] ?? '';
                            final title = video['title'] ?? 'Нэргүй видео';
                            final duration = _formatDuration(video['duration']);
                            final thumbnailUrl = video['thumbnail'] ?? '';
                            
                            final formats = _videoSelectionMap[id] ?? {'mp3': false, 'mp4': false};
                            final bool isMp3Checked = formats['mp3'] ?? false;
                            final bool isMp4Checked = formats['mp4'] ?? false;
                            final bool isMainChecked = isMp3Checked || isMp4Checked;

                            final bool isThisPlaying = _currentPlayingIndex == index && _isPlaying;

                            return Card(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              child: ListTile(
                                leading: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Checkbox(
                                      value: isMainChecked,
                                      onChanged: _isDownloading ? null : (bool? value) {
                                        setState(() {
                                          formats['mp3'] = value ?? false;
                                          formats['mp4'] = value ?? false;
                                        });
                                      },
                                    ),
                                    const SizedBox(width: 4),
                                    InkWell(
                                      onTap: () => _playAudio(index),
                                      borderRadius: BorderRadius.circular(6),
                                      child: Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(6),
                                            child: Image.network(thumbnailUrl, width: 75, height: 45, fit: BoxFit.cover),
                                          ),
                                          Container(
                                            width: 75,
                                            height: 45,
                                            decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(6)),
                                            child: Icon(
                                              isThisPlaying ? Icons.pause : Icons.play_arrow, 
                                              color: Colors.white, 
                                              size: 24
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: isThisPlaying ? const Color(0xFF5992C6) : (isMainChecked ? const Color(0xFF0A2A92) : const Color(0xFF2D3748)), fontWeight: (isMainChecked || isThisPlaying) ? FontWeight.bold : FontWeight.normal, fontSize: 14)),
                                subtitle: Text('Хугацаа: $duration', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Row(
                                      children: [
                                        Text('MP3', style: TextStyle(fontSize: 12, color: Colors.grey[700], fontWeight: FontWeight.bold)),
                                        Checkbox(
                                          value: isMp3Checked,
                                          onChanged: _isDownloading ? null : (bool? value) {
                                            setState(() { formats['mp3'] = value ?? false; });
                                          },
                                        ),
                                      ],
                                    ),
                                    const SizedBox(width: 4),
                                    Row(
                                      children: [
                                        Text('MP4', style: TextStyle(fontSize: 12, color: Colors.grey[700], fontWeight: FontWeight.bold)),
                                        Checkbox(
                                          value: isMp4Checked,
                                          onChanged: _isDownloading ? null : (bool? value) {
                                            setState(() { formats['mp4'] = value ?? false; });
                                          },
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
                
                // 🔥 ЗӨВ БАЙРЛАЛ: АУДИО ТОГЛУУЛАГЧИЙГ FOOTER-ИЙН ДЭЭД ТАЛД ОРУУЛАВ
                if (_currentPlayingTitle.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    height: 72,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A2A92),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 2))]
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.network(_currentPlayingThumbnail, width: 80, height: 50, fit: BoxFit.cover),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_currentPlayingTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                              const SizedBox(height: 2),
                              Text(_isAudioLoading ? 'Урсгал ачаалж байна...' : 'Дарааллаас тоглуулж байна', style: const TextStyle(color: Color(0xFF5992C6), fontSize: 11)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.skip_previous_rounded, size: 28, color: Colors.white),
                              onPressed: _isAudioLoading ? null : _playPrevious,
                            ),
                            IconButton(
                              icon: _isAudioLoading 
                                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : Icon(_isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled, size: 38, color: Colors.white),
                              onPressed: _isAudioLoading ? null : () {
                                if (_isPlaying) { _audioPlayer?.pause(); } else { _audioPlayer?.play(); }
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.skip_next_rounded, size: 28, color: Colors.white),
                              onPressed: _isAudioLoading ? null : _playNext,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 16),
                
                // 🔒 FOOTER ХАМГИЙН ДООРОО БАТ БАЙРЛАЛАА ХАДГАЛЛАА
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "Developed by Ankhbayar Bayarsaikhan and Gemini AI. © 2026.",
                        style: TextStyle(color: Colors.grey[600], fontSize: 13, fontWeight: FontWeight.w500),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      InkWell(
                        onTap: () {
                          html.window.open('https://opensource.org/licenses/MIT', '_blank');
                        },
                        borderRadius: BorderRadius.circular(4),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
                          child: Text(
                            "Released under the MIT Open Source License",
                            style: TextStyle(
                              color: Color(0xFF5992C6),
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              decoration: TextDecoration.underline,
                              decorationColor: Color(0xFF5992C6),
                            ),
                          ),
                        ),
                      ),
                    ],
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