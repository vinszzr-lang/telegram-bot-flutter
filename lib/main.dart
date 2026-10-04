import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const GridRankApp());

enum Cell { empty, x, o }
enum ScreenMode { home, selecting, playing, result }

class GridRankApp extends StatefulWidget {
  const GridRankApp({super.key});

  @override
  State<GridRankApp> createState() => _GridRankAppState();
}

class _GridRankAppState extends State<GridRankApp> with TickerProviderStateMixin {
  final Random _rng = Random();
  final TextEditingController _name = TextEditingController(text: 'PLAYER');

  int stars = 0;
  int size = 4;
  late List<Cell> board;
  Cell turn = Cell.x;
  bool thinking = false;
  bool gameOver = false;
  List<int> winning = const [];
  String result = '';
  ScreenMode screen = ScreenMode.home;
  bool _showStarResult = false;
  bool _starApplied = false;
  Timer? _thinkTimer;
  Timer? _sequenceTimer;

  int get target => size - 1;
  int get rankIndex => stars ~/ 5;
  int get rankStars => stars % 5;

  String get rankName => const [
        'BRONZE',
        'SILVER',
        'GOLD',
        'PLATINUM',
        'DIAMOND',
        'MASTER',
        'GRANDMASTER',
        'MYTHIC',
        'LEGEND',
        'IMMORTAL',
      ][min(rankIndex, 9)];

  @override
  void initState() {
    super.initState();
    _resetBoardOnly();
  }

  @override
  void dispose() {
    _thinkTimer?.cancel();
    _sequenceTimer?.cancel();
    _name.dispose();
    super.dispose();
  }

  void _resetBoardOnly() {
    size = 4 + _rng.nextInt(5);
    board = List.filled(size * size, Cell.empty);
    turn = Cell.x;
    thinking = false;
    gameOver = false;
    winning = const [];
    result = '';
    _showStarResult = false;
    _starApplied = false;
  }

  Future<void> _startRanked() async {
    if (screen == ScreenMode.selecting || screen == ScreenMode.playing) return;
    _thinkTimer?.cancel();
    _sequenceTimer?.cancel();
    setState(() {
      screen = ScreenMode.selecting;
      _resetBoardOnly();
    });

    await Future<void>.delayed(const Duration(milliseconds: 1250));
    if (!mounted || screen != ScreenMode.selecting) return;

    setState(() {
      size = 4 + _rng.nextInt(5);
      board = List.filled(size * size, Cell.empty);
      turn = Cell.x;
      thinking = false;
      gameOver = false;
      winning = const [];
      result = '';
      screen = ScreenMode.playing;
    });
  }

  void _nextMatch() {
    _startRanked();
  }

  void _play(int index) {
    if (screen != ScreenMode.playing || gameOver || thinking || turn != Cell.x || board[index] != Cell.empty) return;

    SystemSound.play(SystemSoundType.click);
    setState(() {
      board[index] = Cell.x;
      turn = Cell.o;
    });

    final win = _findWin(board, Cell.x);
    if (win != null) {
      _finish(true, win);
      return;
    }

    if (_isFull(board)) {
      _finishByNoDraw();
      return;
    }

    _botTurn();
  }

  void _botTurn() {
    setState(() => thinking = true);

    // Deliberately slower than a normal UI tap so the bot feels like it is thinking.
    final rankDelay = min(rankIndex, 9) * 45;
    final delay = 850 + _rng.nextInt(550) + rankDelay;
    _thinkTimer?.cancel();
    _thinkTimer = Timer(Duration(milliseconds: delay), () {
      if (!mounted || screen != ScreenMode.playing || gameOver) return;

      final move = _bestMove();
      setState(() {
        board[move] = Cell.o;
        turn = Cell.x;
        thinking = false;
      });

      final win = _findWin(board, Cell.o);
      if (win != null) {
        _finish(false, win);
      } else if (_isFull(board)) {
        _finishByNoDraw();
      }
    });
  }

  void _finish(bool playerWon, List<int> line) {
    if (gameOver) return;
    _thinkTimer?.cancel();
    final delta = playerWon ? 1 : -1;
    final nextStars = max(0, stars + delta);
    SystemSound.play(SystemSoundType.click);
    setState(() {
      gameOver = true;
      thinking = false;
      winning = line;
      result = playerWon ? 'VICTORY' : 'DEFEAT';
      screen = ScreenMode.result;
      _showStarResult = false;
      _starApplied = false;
    });

    // Result animation first. Only after it finishes do we show the star change.
    _sequenceTimer?.cancel();
    _sequenceTimer = Timer(const Duration(milliseconds: 1350), () {
      if (!mounted || screen != ScreenMode.result) return;
      setState(() => _showStarResult = true);

      // Apply the actual ranked score after the star animation has been visible.
      _sequenceTimer = Timer(const Duration(milliseconds: 950), () {
        if (!mounted || screen != ScreenMode.result || _starApplied) return;
        setState(() {
          stars = nextStars;
          _starApplied = true;
        });
      });
    });
  }

  void _finishByNoDraw() {
    // A ranked match never ends as a draw. If the board fills without a line,
    // award the result to the side with the stronger set of open threats.
    final x = _positionScore(Cell.x);
    final o = _positionScore(Cell.o);
    final playerWon = x >= o;
    final last = board.lastIndexWhere((c) => c != Cell.empty);
    _finish(playerWon, last >= 0 ? [last] : const []);
  }

  bool _isFull(List<Cell> b) => !b.contains(Cell.empty);

  List<int>? _findWin(List<Cell> b, Cell who) {
    for (final line in _allSegments()) {
      if (line.every((i) => b[i] == who)) return line;
    }
    return null;
  }

  List<List<int>> _allSegments() {
    final out = <List<int>>[];
    final k = target;
    for (int r = 0; r < size; r++) {
      for (int c = 0; c <= size - k; c++) {
        out.add(List.generate(k, (i) => r * size + c + i));
      }
    }
    for (int c = 0; c < size; c++) {
      for (int r = 0; r <= size - k; r++) {
        out.add(List.generate(k, (i) => (r + i) * size + c));
      }
    }
    for (int r = 0; r <= size - k; r++) {
      for (int c = 0; c <= size - k; c++) {
        out.add(List.generate(k, (i) => (r + i) * size + c + i));
      }
    }
    for (int r = 0; r <= size - k; r++) {
      for (int c = k - 1; c < size; c++) {
        out.add(List.generate(k, (i) => (r + i) * size + c - i));
      }
    }
    return out;
  }

  int _bestMove() {
    final empties = [for (int i = 0; i < board.length; i++) if (board[i] == Cell.empty) i];
    if (empties.length == 1) return empties.first;

    // Difficulty scales with rank. Bronze intentionally makes mistakes,
    // while higher ranks progressively use stronger tactical/search play.
    final r = min(rankIndex, 9);
    final roll = _rng.nextDouble();

    // Bronze: mostly positional/random play. It can finish a winning line,
    // but it does not always see the player's threat.
    if (r == 0) {
      final winningMoves = <int>[];
      for (final m in empties) {
        board[m] = Cell.o;
        if (_findWin(board, Cell.o) != null) winningMoves.add(m);
        board[m] = Cell.empty;
      }
      if (winningMoves.isNotEmpty && roll < .82) return winningMoves[_rng.nextInt(winningMoves.length)];
      final candidates = _candidateMoves(empties);
      return candidates[_rng.nextInt(candidates.length)];
    }

    // Silver: usually blocks, but occasionally overlooks a threat.
    final mustWin = <int>[];
    final mustBlock = <int>[];
    for (final m in empties) {
      board[m] = Cell.o;
      if (_findWin(board, Cell.o) != null) mustWin.add(m);
      board[m] = Cell.empty;
      board[m] = Cell.x;
      if (_findWin(board, Cell.x) != null) mustBlock.add(m);
      board[m] = Cell.empty;
    }
    if (mustWin.isNotEmpty) return mustWin[_rng.nextInt(mustWin.length)];
    if (r == 1 && mustBlock.isNotEmpty && roll < .78) {
      return mustBlock[_rng.nextInt(mustBlock.length)];
    }
    if (r >= 2 && mustBlock.isNotEmpty) return mustBlock[_rng.nextInt(mustBlock.length)];

    final candidates = _candidateMoves(empties);
    final depth = r >= 8 ? 3 : r >= 4 ? 2 : 1;
    int best = candidates.first;
    int bestScore = -1 << 30;

    for (final m in candidates) {
      board[m] = Cell.o;
      var score = _heuristic(Cell.o) - _heuristic(Cell.x);
      score += _centerAndConnectivity(m) * (r + 2);
      score += _winningThreatCount(Cell.o) * (70 + r * 12);
      score -= _winningThreatCount(Cell.x) * (80 + r * 14);
      if (depth >= 2) score += _search(depth - 1, Cell.x, -1000000, 1000000);
      board[m] = Cell.empty;
      score += _rng.nextInt(r <= 2 ? 20 : 5);
      if (score > bestScore) {
        bestScore = score;
        best = m;
      }
    }
    return best;
  }

  int _search(int depth, Cell who, int alpha, int beta) {
    if (depth <= 0) return _heuristic(Cell.o) - _heuristic(Cell.x);

    final empties = [for (int i = 0; i < board.length; i++) if (board[i] == Cell.empty) i];
    if (empties.isEmpty) return _heuristic(Cell.o) - _heuristic(Cell.x);

    final candidates = _candidateMoves(empties).take(rankIndex >= 7 ? 12 : 8);
    if (who == Cell.o) {
      var best = -1000000;
      for (final m in candidates) {
        board[m] = who;
        final win = _findWin(board, who) != null;
        final value = win ? 500000 : _search(depth - 1, Cell.x, alpha, beta);
        board[m] = Cell.empty;
        best = max(best, value);
        alpha = max(alpha, best);
        if (beta <= alpha) break;
      }
      return best;
    } else {
      var best = 1000000;
      for (final m in candidates) {
        board[m] = who;
        final win = _findWin(board, who) != null;
        final value = win ? -500000 : _search(depth - 1, Cell.o, alpha, beta);
        board[m] = Cell.empty;
        best = min(best, value);
        beta = min(beta, best);
        if (beta <= alpha) break;
      }
      return best;
    }
  }

  int _winningThreatCount(Cell who) {
    var count = 0;
    for (int i = 0; i < board.length; i++) {
      if (board[i] != Cell.empty) continue;
      board[i] = who;
      if (_findWin(board, who) != null) count++;
      board[i] = Cell.empty;
    }
    return count;
  }

  int _centerAndConnectivity(int index) {
    final r = index ~/ size;
    final c = index % size;
    final center = (size - 1) / 2;
    var score = 30 - (((r - center).abs() + (c - center).abs()) * 6).round();
    for (int dr = -1; dr <= 1; dr++) {
      for (int dc = -1; dc <= 1; dc++) {
        if (dr == 0 && dc == 0) continue;
        final nr = r + dr;
        final nc = c + dc;
        if (nr >= 0 && nr < size && nc >= 0 && nc < size && board[nr * size + nc] == Cell.o) score += 8;
      }
    }
    return score;
  }

  List<int> _candidateMoves(List<int> empties) {
    final center = (size - 1) / 2;
    final sorted = [...empties];
    sorted.sort((a, b) {
      final ar = a ~/ size, ac = a % size;
      final br = b ~/ size, bc = b % size;
      final da = (ar - center).abs() + (ac - center).abs();
      final db = (br - center).abs() + (bc - center).abs();
      return da.compareTo(db);
    });
    final maxCandidates = rankIndex >= 8 ? 30 : rankIndex >= 5 ? 24 : rankIndex >= 2 ? 18 : 12;
    return sorted.take(min(maxCandidates, sorted.length)).toList();
  }

  int _positionScore(Cell who) {
    int score = 0;
    for (final line in _allSegments()) {
      int own = 0;
      int other = 0;
      for (final i in line) {
        if (board[i] == who) own++;
        if (board[i] != Cell.empty && board[i] != who) other++;
      }
      if (other == 0) score += pow(4, own).toInt();
    }
    return score;
  }

  int _heuristic(Cell who) {
    int score = 0;
    for (final line in _allSegments()) {
      int own = 0;
      int opp = 0;
      for (final i in line) {
        if (board[i] == who) own++;
        if (board[i] != Cell.empty && board[i] != who) opp++;
      }
      if (opp == 0) score += pow(7, own).toInt();
      if (own == 0 && opp > 0) score -= pow(5, opp).toInt();
    }
    return score;
  }

  Future<void> _showName() async {
    final temp = TextEditingController(text: _name.text.trim());
    final value = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Ganti Nickname'),
        content: TextField(
          controller: temp,
          maxLength: 14,
          autofocus: true,
          textInputAction: TextInputAction.done,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            hintText: 'Masukkan nickname',
            prefixIcon: Icon(Icons.person_rounded),
          ),
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('BATAL'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(temp.text),
            icon: const Icon(Icons.check_rounded),
            label: const Text('SIMPAN'),
          ),
        ],
      ),
    );
    temp.dispose();
    if (!mounted || value == null) return;
    final cleaned = value.trim();
    setState(() => _name.text = cleaned.isEmpty ? 'PLAYER' : cleaned);
  }

  void _showRankGuide() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: const Color(0xFF090B12),
        insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 10, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('RANK & KESULITAN BOT', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Flexible(
              child: InteractiveViewer(
                minScale: .75,
                maxScale: 3.0,
                child: Image.asset('rank_system.png', fit: BoxFit.contain),
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                '⭐ $stars bintang diperoleh  •  $rankName',
                style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.amberAccent),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF090B12),
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF7C5CFF), brightness: Brightness.dark),
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('GRID RANK', style: TextStyle(fontWeight: FontWeight.w900)),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
          actions: screen == ScreenMode.home
              ? [
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert_rounded),
                    onSelected: (value) {
                      if (value == 'help') _showRankGuide();
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem<String>(
                        value: 'help',
                        child: Row(
                          children: [
                            Icon(Icons.help_outline_rounded),
                            SizedBox(width: 10),
                            Text('Cara Main & Rank'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ]
              : null,
        ),
        body: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            child: screen == ScreenMode.home
                ? _home()
                : screen == ScreenMode.selecting
                    ? _selectionScreen()
                    : _gameScreen(),
          ),
        ),
      ),
    );
  }

  Widget _home() {
    final player = _name.text.trim().isEmpty ? 'PLAYER' : _name.text.trim();
    return ListView(
      key: const ValueKey('home'),
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 30),
      children: [
        _profileCard(player),
        const SizedBox(height: 14),
        _rankCard(),
        const SizedBox(height: 22),
        _modePreview(),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: () {
            _startRanked();
          },
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(58), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
          icon: const Icon(Icons.sports_esports_rounded),
          label: const Text('MULAI - RANKED', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, letterSpacing: .5)),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _showName,
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
          icon: const Icon(Icons.edit_rounded),
          label: const Text('GANTI NICKNAME', style: TextStyle(fontWeight: FontWeight.w800)),
        ),
        const SizedBox(height: 20),
        const Text('Mode board dipilih secara acak 4×4 sampai 8×8 setiap match.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54, fontSize: 12)),
      ],
    );
  }

  Widget _profileCard(String player) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: const Color(0xFF151925), borderRadius: BorderRadius.circular(22)),
        child: Row(
          children: [
            CircleAvatar(radius: 25, backgroundColor: const Color(0xFF5A43A9), child: Text(player[0].toUpperCase(), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900))),
            const SizedBox(width: 12),
            Expanded(child: Text(player, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900))),
            const Icon(Icons.star_rounded, color: Colors.amber, size: 27),
            const SizedBox(width: 4),
            Text('$stars', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
          ],
        ),
      );

  Widget _rankCard() => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFF171B2A), Color(0xFF11131D)]),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF7C5CFF).withOpacity(.18)),
              child: const Icon(Icons.workspace_premium_rounded, size: 33),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [Text(rankName, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900)), const Spacer(), Text('$rankStars/5', style: const TextStyle(color: Colors.white60, fontWeight: FontWeight.bold))]),
                  const SizedBox(height: 9),
                  ClipRRect(borderRadius: BorderRadius.circular(10), child: LinearProgressIndicator(value: rankStars / 5, minHeight: 8)),
                  const SizedBox(height: 6),
                  Text(rankStars == 4 ? '1 bintang lagi ke rank berikutnya' : '${5 - rankStars} bintang ke rank berikutnya', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _modePreview() => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: const Color(0xFF11141E), borderRadius: BorderRadius.circular(20)),
        child: Row(
          children: [
            Container(width: 50, height: 50, decoration: BoxDecoration(color: const Color(0xFF7C5CFF).withOpacity(.16), borderRadius: BorderRadius.circular(15)), child: const Icon(Icons.grid_4x4_rounded)),
            const SizedBox(width: 13),
            const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('RANKED VS BOT', style: TextStyle(fontWeight: FontWeight.w900)), SizedBox(height: 5), Text('4×4 → 8×8 • target garis mengikuti ukuran board', style: TextStyle(color: Colors.white54, fontSize: 12))])),
          ],
        ),
      );

  Widget _selectionScreen() => Center(
        key: const ValueKey('selecting'),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.8, end: 1.08),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeInOut,
              builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
              child: Container(
                width: 104,
                height: 104,
                decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF7C5CFF).withOpacity(.14), border: Border.all(color: const Color(0xFF8F73FF), width: 2)),
                child: const Icon(Icons.shuffle_rounded, size: 48),
              ),
            ),
            const SizedBox(height: 28),
            const Text('MEMILIH MODE...', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: 1)),
            const SizedBox(height: 10),
            Text('Menentukan board secara acak 4×4 — 8×8', style: TextStyle(color: Colors.white.withOpacity(.58))),
            const SizedBox(height: 25),
            const SizedBox(width: 190, child: LinearProgressIndicator(minHeight: 5)),
          ],
        ),
      );

  Widget _gameScreen() {
    final player = _name.text.trim().isEmpty ? 'PLAYER' : _name.text.trim();
    final boardMax = MediaQuery.of(context).size.width - 28;
    return Stack(
      key: const ValueKey('game'),
      children: [
        ListView(
          padding: const EdgeInsets.fromLTRB(14, 2, 14, 26),
          children: [
            Row(
              children: [
                _playerLabel(player, Cell.x, true),
                const Spacer(),
                _playerLabel('BOT', Cell.o, false),
              ],
            ),
            const SizedBox(height: 12),
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: boardMax),
                child: AspectRatio(aspectRatio: 1, child: _board()),
              ),
            ),
            const SizedBox(height: 13),
            Text('MATCH $size×$size  •  TARGET $target GARIS', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.1, color: Colors.white70)),
            const SizedBox(height: 12),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: thinking
                  ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)), const SizedBox(width: 8), Text('BOT SEDANG BERPIKIR...', key: const ValueKey('thinking'), style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold))])
                  : Text(turn == Cell.x ? 'GILIRANMU' : 'GILIRAN BOT', key: const ValueKey('turn'), textAlign: TextAlign.center, style: TextStyle(color: turn == Cell.x ? Colors.cyanAccent : Colors.orangeAccent, fontWeight: FontWeight.w900, letterSpacing: 1)),
            ),
          ],
        ),
        if (screen == ScreenMode.result) _resultOverlay(),
      ],
    );
  }

  Widget _playerLabel(String name, Cell mark, bool left) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!left) ...[Text(name, style: const TextStyle(fontWeight: FontWeight.w900)), const SizedBox(width: 8)],
          Text(mark == Cell.x ? 'X' : 'O', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: mark == Cell.x ? Colors.cyanAccent : Colors.orangeAccent)),
          if (left) ...[const SizedBox(width: 8), ConstrainedBox(constraints: const BoxConstraints(maxWidth: 150), child: Text(name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900)))],
        ],
      );

  Widget _board() => Container(
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(color: const Color(0xFF171A26), borderRadius: BorderRadius.circular(17), boxShadow: [BoxShadow(color: Colors.black.withOpacity(.38), blurRadius: 20)]),
        child: GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: size, crossAxisSpacing: 3, mainAxisSpacing: 3),
          itemCount: board.length,
          itemBuilder: (_, i) {
            final c = board[i];
            final isWin = winning.contains(i);
            return InkWell(
              onTap: () => _play(i),
              borderRadius: BorderRadius.circular(6),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                decoration: BoxDecoration(
                  color: isWin ? Colors.green.withOpacity(.28) : const Color(0xFF222635),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: isWin ? Colors.greenAccent.withOpacity(.75) : Colors.white.withOpacity(.025)),
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 170),
                  transitionBuilder: (child, animation) => ScaleTransition(scale: CurvedAnimation(parent: animation, curve: Curves.elasticOut), child: child),
                  child: c == Cell.empty
                      ? const SizedBox(key: ValueKey('empty'))
                      : FittedBox(
                          key: ValueKey('$i-$c'),
                          fit: BoxFit.contain,
                          child: Padding(
                            padding: const EdgeInsets.all(3),
                            child: Text(c == Cell.x ? 'X' : 'O', style: TextStyle(fontSize: 72, fontWeight: FontWeight.w900, height: .9, color: c == Cell.x ? Colors.cyanAccent : Colors.orangeAccent)),
                          ),
                        ),
                ),
              ),
            );
          },
        ),
      );

  Widget _resultOverlay() {
    final victory = result == 'VICTORY';
    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(.74),
        alignment: Alignment.center,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          child: !_showStarResult
              ? _resultTitle(victory)
              : _starAnimation(victory),
        ),
      ),
    );
  }

  Widget _resultTitle(bool victory) => TweenAnimationBuilder<double>(
        key: ValueKey('result-$result'),
        tween: Tween(begin: .45, end: 1),
        duration: const Duration(milliseconds: 900),
        curve: Curves.elasticOut,
        builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: .6, end: 1.0),
              duration: const Duration(milliseconds: 650),
              curve: Curves.easeOutBack,
              builder: (_, s, child) => Transform.scale(scale: s, child: child),
              child: Icon(victory ? Icons.emoji_events_rounded : Icons.close_rounded, size: 92, color: victory ? Colors.amberAccent : Colors.redAccent),
            ),
            const SizedBox(height: 14),
            Text(victory ? 'VICTORY' : 'DEFEAT', style: TextStyle(fontSize: 42, fontWeight: FontWeight.w900, letterSpacing: 2.2, color: victory ? Colors.greenAccent : Colors.redAccent)),
            const SizedBox(height: 8),
            Text(victory ? 'KAMU MENANG!' : 'BOT MENANG!', style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, letterSpacing: 1.1)),
          ],
        ),
      );

  Widget _starAnimation(bool victory) {
    final delta = victory ? 1 : -1;
    final afterStars = max(0, stars + delta);
    return TweenAnimationBuilder<double>(
      key: ValueKey('stars-$result'),
      tween: Tween(begin: .15, end: 1),
      duration: const Duration(milliseconds: 850),
      curve: Curves.elasticOut,
      builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.7, end: 1.12),
            duration: const Duration(milliseconds: 650),
            curve: Curves.easeInOut,
            builder: (_, s, child) => Transform.scale(scale: s, child: child),
            child: const Icon(Icons.star_rounded, size: 92, color: Colors.amber),
          ),
          const SizedBox(height: 8),
          Text(victory ? '+1 STAR' : '-1 STAR', style: const TextStyle(fontSize: 31, fontWeight: FontWeight.w900)),
          const SizedBox(height: 7),
          Text(victory ? 'BINTANG BERTAMBAH!' : (stars > 0 ? 'BINTANG BERKURANG' : 'BINTANG TETAP 0'), style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, letterSpacing: .8)),
          const SizedBox(height: 14),
          Text('TOTAL ⭐ $afterStars', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          const SizedBox(height: 24),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: !_starApplied
                ? const SizedBox(
                    key: ValueKey('updating-stars'),
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : Column(
                    key: const ValueKey('result-actions'),
                    children: [
                      FilledButton.icon(
                        onPressed: _nextMatch,
                        icon: const Icon(Icons.shuffle_rounded),
                        label: const Text('MAIN LAGI'),
                        style: FilledButton.styleFrom(minimumSize: const Size(210, 50)),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: _backToLobby,
                        icon: const Icon(Icons.home_rounded),
                        label: const Text('KEMBALI KE LOBBY'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size(210, 48)),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  void _backToLobby() {
    _thinkTimer?.cancel();
    _sequenceTimer?.cancel();
    setState(() {
      screen = ScreenMode.home;
      gameOver = false;
      thinking = false;
      winning = const [];
      result = '';
      _showStarResult = false;
      _starApplied = false;
    });
  }

}
