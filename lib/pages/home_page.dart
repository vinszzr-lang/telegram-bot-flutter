import 'dart:async';
import 'package:flutter/material.dart';
import '../services/api.dart';
import '../services/session.dart';
import '../services/socket_service.dart';
import '../utils/navigation.dart';
import '../utils/db.dart';
import '../widgets/verified_badge.dart';
import 'add_contact_page.dart';
import 'banned_page.dart';
import 'chat_page.dart';
import 'profile_page.dart';

class HomePage extends StatefulWidget {
  final Session session;
  const HomePage({super.key, required this.session});
  @override State<HomePage> createState()=>_HomePageState();
}

class _HomePageState extends State<HomePage> with RouteAware {
  final api=Api();
  final socket=SocketService();
  final Map<String,Map<String,dynamic>> contactMap={};
  Timer? pollTimer;
  Timer? bannerTimer;
  bool loading=true,syncing=false,routeSubscribed=false;
  String search='';
  String? bannerText;

  @override void initState(){super.initState();_connectSocket();refresh();_startPolling();}
  @override void didChangeDependencies(){super.didChangeDependencies();if(!routeSubscribed){final route=ModalRoute.of(context);if(route is PageRoute){chatWithURouteObserver.subscribe(this,route);routeSubscribed=true;}}}
  void _connectSocket(){if(widget.session.token==null)return;socket.connect(Api.baseUrl,widget.session.token!);socket.on('message:new',_onMessage);socket.on('profile:updated',(_)=>syncFast());socket.on('contacts:updated',(_)=>syncFast());}
  void _onMessage(dynamic raw){if(raw is! Map)return;final sender=raw['senderUsername']?.toString();final recipient=raw['recipientUsername']?.toString();if(sender==null||recipient==null)return;if(recipient!=widget.session.username)return;final c=contactMap[sender];final name=(c?['name']??c?['displayName']??sender).toString();_showBanner('$name mengirim pesan baru');syncFast();}
  void _showBanner(String text){bannerTimer?.cancel();if(!mounted)return;setState(()=>bannerText=text);bannerTimer=Timer(const Duration(seconds:4),(){if(mounted)setState(()=>bannerText=null);});}
  void _clearBanner(){bannerTimer?.cancel();if(mounted)setState(()=>bannerText=null);}
  void _startPolling(){pollTimer?.cancel();pollTimer=Timer.periodic(const Duration(seconds:3),(_)=>syncFast());}
  void _stopPolling(){pollTimer?.cancel();pollTimer=null;}
  @override void didPushNext(){_stopPolling();}
  @override void didPopNext(){_clearBanner();_startPolling();syncFast();}
  Future<void> refresh()=>syncFast(forceLoading:true);
  Future<void> syncFast({bool forceLoading=false})async{if(syncing||widget.session.token==null)return;syncing=true;if(forceLoading&&mounted)setState(()=>loading=true);try{final data=await api.sync(widget.session.token!);final user=Map<String,dynamic>.from(data['user']??{});await widget.session.updateUser(user);final next=<String,Map<String,dynamic>>{};_mergeInto(next,data['contacts']);_mergeInto(next,data['inbox']);for(final e in next.entries){final marker=await LocalCache.readAt(e.key);final lastRaw=e.value['lastMessageAt']?.toString();final last=lastRaw==null?null:DateTime.tryParse(lastRaw)?.toUtc();if(marker!=null&&last!=null&&!last.isAfter(marker))e.value['unread']=0;}contactMap..clear()..addAll(next);if(mounted)setState(()=>loading=false);}on ApiException catch(e){if(e.status==403)_showBanned();if(mounted)setState(()=>loading=false);}catch(_){if(mounted)setState(()=>loading=false);}finally{syncing=false;}}
  void _mergeInto(Map<String,Map<String,dynamic>> target,dynamic raw){if(raw is! List)return;for(final item in raw){if(item is! Map)continue;final c=Map<String,dynamic>.from(item);final u=c['username']?.toString();if(u==null||u.isEmpty)continue;target[u]={...?target[u],...c};}}
  void _showBanned(){if(!mounted)return;_stopPolling();Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder:(_)=>BannedPage(session:widget.session)),(_)=>false);}
  @override void dispose(){_stopPolling();bannerTimer?.cancel();socket.disconnect();if(routeSubscribed)chatWithURouteObserver.unsubscribe(this);super.dispose();}

  @override
  Widget build(BuildContext context) {
    final filtered = contactMap.values.where((c) {
      final text = '${c['name'] ?? ''} ${c['displayName'] ?? ''} ${c['username'] ?? ''}'.toLowerCase();
      return text.contains(search);
    }).toList()..sort((a, b) => (b['lastMessageAt'] ?? '').toString().compareTo((a['lastMessageAt'] ?? '').toString()));

    return Scaffold(
      backgroundColor: const Color(0xFF080D10),
      appBar: AppBar(
        backgroundColor: const Color(0xFF080D10),
        elevation: 0,
        titleSpacing: 16,
        title: Row(children: [
          Container(width: 40, height: 40, decoration: BoxDecoration(borderRadius: BorderRadius.circular(13), gradient: const LinearGradient(colors: [Color(0xFF6C4DFF), Color(0xFF20C76B)])), child: const Icon(Icons.forum_rounded, size: 22)),
          const SizedBox(width: 10),
          const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('ChatWithU', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900)), Text('Private • Realtime', style: TextStyle(fontSize: 10, color: Colors.white54))]),
        ]),
        actions: [IconButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ProfilePage(session: widget.session))).then((_) => refresh()), icon: const Icon(Icons.account_circle_outlined, size: 27))],
      ),
      body: Column(
        children: [
          if (bannerText != null) _NotificationBanner(text: bannerText!, onClose: _clearBanner),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
            child: TextField(
              onChanged: (v) => setState(() => search = v.toLowerCase()),
              decoration: InputDecoration(
                hintText: 'Cari teman atau username',
                prefixIcon: const Icon(Icons.search_rounded),
                filled: true,
                fillColor: const Color(0xFF171F23),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
              ),
            ),
          ),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: refresh,
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: filtered.length,
                      itemBuilder: (_, i) => _tile(filtered[i]),
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        onPressed: () async {
          final ok = await Navigator.push(context, MaterialPageRoute(builder: (_) => AddContactPage(session: widget.session)));
          if (ok == true) refresh();
        },
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _tile(Map<String,dynamic> c){final u=(c['username']??'').toString();final name=(c['name']??c['displayName']??u).toString();final avatar=(c['avatarUrl']??'').toString();final verified=c['verified']==true;final unread=(c['unread']??0) as int;return Container(margin:const EdgeInsets.symmetric(horizontal:10,vertical:3),decoration:BoxDecoration(color:const Color(0xFF10171A),borderRadius:BorderRadius.circular(18),border:Border.all(color:Colors.white.withValues(alpha: .035))),child:ListTile(contentPadding:const EdgeInsets.symmetric(horizontal:12,vertical:5),leading:Stack(children:[CircleAvatar(radius:27,backgroundColor:const Color(0xFF2A1D38),backgroundImage:avatar.isNotEmpty?NetworkImage(avatar):null,child:avatar.isEmpty?Text(name.isEmpty?'?':name[0].toUpperCase(),style:const TextStyle(fontWeight:FontWeight.w800)):null),if(unread>0)Positioned(right:-1,bottom:-1,child:Container(width:15,height:15,decoration:const BoxDecoration(color:Color(0xFF20C76B),shape:BoxShape.circle),child:Center(child:Text(unread>9?'9+':'$unread',style:const TextStyle(fontSize:7,fontWeight:FontWeight.w900)))))]),title:Row(children:[Flexible(child:Text(name,style:const TextStyle(fontWeight:FontWeight.w800),overflow:TextOverflow.ellipsis)),if(verified)const Padding(padding:EdgeInsets.only(left:5),child:VerifiedBadge())]),subtitle:Padding(padding:const EdgeInsets.only(top:4),child:Text(c['lastMessage']?.toString().isNotEmpty==true?c['lastMessage'].toString():'@$u',maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Colors.white54))),trailing:Text(c['lastMessageAt']!=null?_listTime(c['lastMessageAt']):'',style:TextStyle(fontSize:11,color:unread>0?const Color(0xFF20C76B):Colors.white38,fontWeight:unread>0?FontWeight.w700:FontWeight.normal)),onTap:()async{final lastRaw=c['lastMessageAt']?.toString();final last=lastRaw==null?DateTime.now().toUtc():DateTime.tryParse(lastRaw)?.toUtc()??DateTime.now().toUtc();c['unread']=0;await LocalCache.markRead(u,last.toIso8601String());_clearBanner();if(!mounted)return;await Navigator.push(context,MaterialPageRoute(builder:(_)=>ChatPage(session:widget.session,contact:c)));_clearBanner();await refresh();}));}
  String _listTime(dynamic value){final d=DateTime.tryParse(value.toString())?.toLocal();if(d==null)return'';final now=DateTime.now();final today=DateTime(now.year,now.month,now.day);final day=DateTime(d.year,d.month,d.day);final diff=today.difference(day).inDays;if(diff==0)return'${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';if(diff==1)return'Kemarin';return'${d.day.toString().padLeft(2,'0')}/${d.month.toString().padLeft(2,'0')}/${d.year}';}
}
class _NotificationBanner extends StatelessWidget{final String text;final VoidCallback onClose;const _NotificationBanner({required this.text,required this.onClose});@override Widget build(BuildContext context)=>Material(color:const Color(0xFF1E3B31),child:InkWell(onTap:onClose,child:Padding(padding:const EdgeInsets.symmetric(horizontal:16,vertical:11),child:Row(children:[const Icon(Icons.notifications_active_outlined,size:20),const SizedBox(width:10),Expanded(child:Text(text,style:const TextStyle(fontWeight:FontWeight.w600))),IconButton(onPressed:onClose,icon:const Icon(Icons.close,size:18))]))));}
