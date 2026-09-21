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
  void _connectSocket(){if(widget.session.token==null)return;socket.connect(Api.baseUrl,widget.session.token!);socket.on('message:new',_onMessage);socket.on('profile:updated',(_)=>syncFast());}
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
        title: const Text('ChatWithU', style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800)),
        actions: [IconButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ProfilePage(session: widget.session))).then((_) => refresh()), icon: const Icon(Icons.more_vert))],
      ),
      body: Column(
        children: [
          if (bannerText != null) _NotificationBanner(text: bannerText!, onClose: _clearBanner),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
            child: TextField(
              onChanged: (v) => setState(() => search = v.toLowerCase()),
              decoration: InputDecoration(hintText: 'Cari...', prefixIcon: const Icon(Icons.search), filled: true, fillColor: const Color(0xFF20272B), border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none)),
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

  Widget _tile(Map<String,dynamic> c){final u=(c['username']??'').toString();final name=(c['name']??c['displayName']??u).toString();final avatar=(c['avatarUrl']??'').toString();final verified=c['verified']==true;return ListTile(contentPadding:const EdgeInsets.symmetric(horizontal:16,vertical:4),leading:CircleAvatar(radius:25,backgroundColor:const Color(0xFF2A1D38),backgroundImage:avatar.isNotEmpty?NetworkImage(avatar):null,child:avatar.isEmpty?Text(name.isEmpty?'?':name[0].toUpperCase()):null),title:Row(children:[Flexible(child:Text(name,style:const TextStyle(fontWeight:FontWeight.w700),overflow:TextOverflow.ellipsis)),if(verified)const Padding(padding:EdgeInsets.only(left:5),child:VerifiedBadge())]),subtitle:Text(c['lastMessage']?.toString().isNotEmpty==true?c['lastMessage'].toString():'@$u',maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Colors.white54)),trailing:Column(mainAxisAlignment:MainAxisAlignment.center,crossAxisAlignment:CrossAxisAlignment.end,children:[if(c['lastMessageAt']!=null)Text(_listTime(c['lastMessageAt']),style:const TextStyle(fontSize:11,color:Colors.white54)),if((c['unread']??0)>0)Container(margin:const EdgeInsets.only(top:5),padding:const EdgeInsets.symmetric(horizontal:7,vertical:3),decoration:BoxDecoration(color:const Color(0xFF6C4DFF),borderRadius:BorderRadius.circular(20)),child:Text('${c['unread']}',style:const TextStyle(fontSize:11,fontWeight:FontWeight.bold)))]),onTap:()async{final lastRaw=c['lastMessageAt']?.toString();final last=lastRaw==null?DateTime.now().toUtc():DateTime.tryParse(lastRaw)?.toUtc()??DateTime.now().toUtc();c['unread']=0;await LocalCache.markRead(u,last.toIso8601String());_clearBanner();if(!mounted)return;await Navigator.push(context,MaterialPageRoute(builder:(_)=>ChatPage(session:widget.session,contact:c)));_clearBanner();await refresh();});}
  String _listTime(dynamic value){final d=DateTime.tryParse(value.toString())?.toLocal();if(d==null)return'';final now=DateTime.now();final today=DateTime(now.year,now.month,now.day);final day=DateTime(d.year,d.month,d.day);final diff=today.difference(day).inDays;if(diff==0)return'${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';if(diff==1)return'Kemarin';return'${d.day.toString().padLeft(2,'0')}/${d.month.toString().padLeft(2,'0')}/${d.year}';}
}
class _NotificationBanner extends StatelessWidget{final String text;final VoidCallback onClose;const _NotificationBanner({required this.text,required this.onClose});@override Widget build(BuildContext context)=>Material(color:const Color(0xFF1E3B31),child:InkWell(onTap:onClose,child:Padding(padding:const EdgeInsets.symmetric(horizontal:16,vertical:11),child:Row(children:[const Icon(Icons.notifications_active_outlined,size:20),const SizedBox(width:10),Expanded(child:Text(text,style:const TextStyle(fontWeight:FontWeight.w600))),IconButton(onPressed:onClose,icon:const Icon(Icons.close,size:18))]))));}
