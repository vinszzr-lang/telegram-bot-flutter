import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';

void main() => runApp(const GridRankApp());

enum Cell { empty, x, o }

class GridRankApp extends StatefulWidget {
  const GridRankApp({super.key});
  @override
  State<GridRankApp> createState() => _GridRankAppState();
}

class _GridRankAppState extends State<GridRankApp> {
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
  Timer? _thinkTimer;

  int get target => size - 1;
  int get rankIndex => stars ~/ 5;
  int get rankStars => stars % 5;
  String get rankName => const [
        'BRONZE', 'SILVER', 'GOLD', 'PLATINUM', 'DIAMOND',
        'MASTER', 'GRANDMASTER', 'MYTHIC', 'LEGEND', 'IMMORTAL'
      ][min(rankIndex, 9)];

  @override
  void initState() {
    super.initState();
    _newGame();
  }

  @override
  void dispose() {
    _thinkTimer?.cancel();
    _name.dispose();
    super.dispose();
  }

  void _newGame() {
    _thinkTimer?.cancel();
    setState(() {
      size = 4 + _rng.nextInt(5);
      board = List.filled(size * size, Cell.empty);
      turn = Cell.x;
      thinking = false;
      gameOver = false;
      winning = const [];
      result = '';
    });
  }

  void _play(int index) {
    if (gameOver || thinking || turn != Cell.x || board[index] != Cell.empty) return;
    setState(() {
      board[index] = Cell.x;
      turn = Cell.o;
    });
    final win = _findWin(board, Cell.x);
    if (win != null) {
      _finish(true, win);
      return;
    }
    _botTurn();
  }

  void _botTurn() {
    thinking = true;
    _thinkTimer = Timer(Duration(milliseconds: 240 + _rng.nextInt(260)), () {
      if (!mounted || gameOver) return;
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
        _tieBreak();
      }
    });
  }

  void _finish(bool playerWon, List<int> line) {
    setState(() {
      gameOver = true;
      winning = line;
      if (playerWon) {
        stars++;
        result = 'VICTORY';
      } else {
        stars = max(0, stars - 1);
        result = 'DEFEAT';
      }
    });
  }

  // No draw: if the board fills without a k-line, the side with the stronger
  // near-line position wins; the final move is the deterministic tie-breaker.
  void _tieBreak() {
    final x = _positionScore(Cell.x);
    final o = _positionScore(Cell.o);
    final playerWon = x >= o;
    final last = board.lastIndexWhere((c) => c != Cell.empty);
    _finish(playerWon, last >= 0 ? [last] : const []);
  }

  int _positionScore(Cell who) {
    int score = 0;
    for (final line in _allSegments()) {
      final count = line.where((i) => board[i] == who).length;
      final other = line.where((i) => board[i] != Cell.empty && board[i] != who).length;
      if (other == 0) score += pow(4, count).toInt();
    }
    return score;
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

    // Always take an immediate win.
    for (final m in empties) {
      board[m] = Cell.o;
      final win = _findWin(board, Cell.o);
      board[m] = Cell.empty;
      if (win != null) return m;
    }
    // Always block an immediate player win.
    for (final m in empties) {
      board[m] = Cell.x;
      final win = _findWin(board, Cell.x);
      board[m] = Cell.empty;
      if (win != null) return m;
    }

    final candidates = _candidateMoves(empties);
    final depth = rankIndex >= 7 ? 3 : rankIndex >= 4 ? 2 : 1;
    int best = candidates.first;
    int bestScore = -1 << 30;
    for (final m in candidates) {
      board[m] = Cell.o;
      int score = _heuristic(Cell.o) - _heuristic(Cell.x);
      if (depth >= 2) score += _lookAhead(depth - 1, Cell.x);
      board[m] = Cell.empty;
      score += _rng.nextInt(7);
      if (score > bestScore) {
        bestScore = score;
        best = m;
      }
    }
    return best;
  }

  List<int> _candidateMoves(List<int> empties) {
    final center = (size - 1) / 2;
    empties.sort((a, b) {
      final ar = a ~/ size, ac = a % size;
      final br = b ~/ size, bc = b % size;
      final da = (ar - center).abs() + (ac - center).abs();
      final db = (br - center).abs() + (bc - center).abs();
      return da.compareTo(db);
    });
    final maxCandidates = rankIndex >= 6 ? 24 : rankIndex >= 3 ? 16 : 10;
    return empties.take(min(maxCandidates, empties.length)).toList();
  }

  int _lookAhead(int depth, Cell who) {
    if (depth <= 0) return _heuristic(Cell.o) - _heuristic(Cell.x);
    final empties = [for (int i = 0; i < board.length; i++) if (board[i] == Cell.empty) i];
    if (empties.isEmpty) return 0;
    int best = who == Cell.o ? -1 << 30 : 1 << 30;
    for (final m in _candidateMoves(empties).take(12)) {
      board[m] = who;
      final win = _findWin(board, who) != null;
      int value;
      if (win) {
        value = who == Cell.o ? 100000 : -100000;
      } else {
        value = _lookAhead(depth - 1, who == Cell.o ? Cell.x : Cell.o);
      }
      board[m] = Cell.empty;
      if (who == Cell.o) best = max(best, value); else best = min(best, value);
    }
    return best;
  }

  int _heuristic(Cell who) {
    int score = 0;
    for (final line in _allSegments()) {
      int own = 0, opp = 0;
      for (final i in line) {
        if (board[i] == who) own++;
        if (board[i] != Cell.empty && board[i] != who) opp++;
      }
      if (opp == 0) score += pow(6, own).toInt();
      if (own == 0 && opp > 0) score -= pow(3, opp).toInt();
    }
    return score;
  }

  @override
  Widget build(BuildContext context) {
    final boardMax = MediaQuery.of(context).size.width - 28;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF090B12),
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF7C5CFF), brightness: Brightness.dark),
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('GRID RANK'),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          actions: [IconButton(onPressed: _newGame, icon: const Icon(Icons.refresh_rounded))],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 24),
            children: [
              _profileBar(),
              const SizedBox(height: 14),
              _rankCard(),
              const SizedBox(height: 14),
              Row(
                children: [
                  _playerLabel(_name.text.isEmpty ? 'PLAYER' : _name.text, Cell.x, true),
                  const Spacer(),
                  _playerLabel('BOT • $rankName', Cell.o, false),
                ],
              ),
              const SizedBox(height: 12),
              Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: boardMax),
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: _board(),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'MATCH $size×$size  •  TARGET $target GARIS',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 1.2, color: Colors.white70),
              ),
              const SizedBox(height: 12),
              if (thinking) const LinearProgressIndicator(minHeight: 3),
              if (gameOver) ...[
                const SizedBox(height: 8),
                Text(result, textAlign: TextAlign.center, style: TextStyle(fontSize: 27, fontWeight: FontWeight.w900, color: result == 'VICTORY' ? Colors.greenAccent : Colors.redAccent)),
                const SizedBox(height: 4),
                Text(result == 'VICTORY' ? '+1 STAR' : '-1 STAR', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                FilledButton.icon(onPressed: _newGame, icon: const Icon(Icons.sports_esports), label: const Text('NEXT MATCH')),
              ],
              const SizedBox(height: 12),
              OutlinedButton.icon(onPressed: () => _showName(), icon: const Icon(Icons.edit_rounded), label: const Text('CHANGE NICKNAME')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _profileBar() => Row(children: [
        CircleAvatar(radius: 22, child: Text((_name.text.isEmpty ? 'P' : _name.text[0]).toUpperCase())),
        const SizedBox(width: 10),
        Expanded(child: Text(_name.text.isEmpty ? 'PLAYER' : _name.text, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
        const Icon(Icons.star_rounded, color: Colors.amber),
        const SizedBox(width: 4),
        Text('$stars', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
      ]);

  Widget _rankCard() => Card(
        elevation: 0,
        color: const Color(0xFF151925),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Container(width: 50, height: 50, decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF7C5CFF).withOpacity(.18)), child: const Icon(Icons.workspace_premium_rounded, size: 30)),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(rankName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)), const SizedBox(height: 7), LinearProgressIndicator(value: (rankStars + 1) / 5, minHeight: 7), const SizedBox(height: 5), Text('$rankStars / 5 stars ke rank berikutnya', style: const TextStyle(color: Colors.white60, fontSize: 12))])),
          ]),
        ),
      );

  Widget _playerLabel(String name, Cell mark, bool left) => Row(mainAxisSize: MainAxisSize.min, children: [
        if (!left) ...[Text(name, style: const TextStyle(fontWeight: FontWeight.bold)), const SizedBox(width: 8)],
        Text(mark == Cell.x ? 'X' : 'O', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900, color: mark == Cell.x ? Colors.cyanAccent : Colors.orangeAccent)),
        if (left) ...[const SizedBox(width: 8), ConstrainedBox(constraints: const BoxConstraints(maxWidth: 130), child: Text(name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)))],
      ]);

  Widget _board() => Container(
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(color: const Color(0xFF171A26), borderRadius: BorderRadius.circular(16), boxShadow: [BoxShadow(color: Colors.black.withOpacity(.35), blurRadius: 18)]),
        child: GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: size, crossAxisSpacing: 3, mainAxisSpacing: 3),
          itemCount: board.length,
          itemBuilder: (_, i) {
            final c = board[i];
            final isWin = winning.contains(i);
            return InkWell(
              onTap: () => _play(i),
              borderRadius: BorderRadius.circular(5),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                decoration: BoxDecoration(color: isWin ? Colors.green.withOpacity(.28) : const Color(0xFF222635), borderRadius: BorderRadius.circular(5)),
                child: Center(child: Text(c == Cell.x ? 'X' : c == Cell.o ? 'O' : '', style: TextStyle(fontSize: max(15, 48 / size), fontWeight: FontWeight.w900, color: c == Cell.x ? Colors.cyanAccent : Colors.orangeAccent))),
              ),
            );
          },
        ),
      );

  Future<void> _showName() async {
    final temp = TextEditingController(text: _name.text);
    await showDialog<void>(context: context, builder: (_) => AlertDialog(title: const Text('Nickname'), content: TextField(controller: temp, maxLength: 14, autofocus: true, decoration: const InputDecoration(hintText: 'Nama pemain')), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')), FilledButton(onPressed: () { setState(() => _name.text = temp.text.trim().isEmpty ? 'PLAYER' : temp.text.trim()); Navigator.pop(context); }, child: const Text('SAVE'))]));
    temp.dispose();
  }
}
