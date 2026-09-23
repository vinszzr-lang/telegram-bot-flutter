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
import 'contact_profile_page.dart';
import 'group_chat_page.dart';
import 'group_pages.dart';
import 'profile_page.dart';
import '../services/notification_service.dart';

class HomePage extends StatefulWidget {
  final Session session;
  const HomePage({super.key, required this.session});
  @override State<HomePage> createState()=>_HomePageState();
}
class _HomePageState extends State<HomePage> with RouteAware {
  final api=Api(), socket=SocketService();
  final contactMap=<String,Map<String,dynamic>>{}; final groupMap=<String,Map<String,dynamic>>{};
  Timer? pollTimer, bannerTimer;
  bool loading = true, syncing = false, routeSubscribed = false;
  String search = '';
  String? bannerText;
  int unreadTotal = 0, tab = 0;
  @override void initState(){super.initState();NotificationService.init();NotificationService.requestPermission();_connect();refresh();_startPolling();}
  @override void didChangeDependencies(){super.didChangeDependencies();if(!routeSubscribed){final r=ModalRoute.of(context);if(r is PageRoute){chatWithURouteObserver.subscribe(this,r);routeSubscribed=true;}}}
  void _connect(){if(widget.session.token==null)return;socket.connect(Api.baseUrl,widget.session.token!);socket.on('message:new',_onMessage);socket.on('group:message:new',_onGroupMessage);socket.on('profile:updated',(_)=>syncFast());socket.on('group:updated',(_)=>syncFast());}
  void _onMessage(dynamic raw){if(raw is! Map)return;final sender=raw['senderUsername']?.toString();final recipient=raw['recipientUsername']?.toString();if(recipient!=widget.session.username)return;final c=contactMap[sender];final name=(c?['name']??c?['displayName']??sender??'Pesan').toString();_showBanner('$name mengirim pesan baru');NotificationService.show(title:name,body:raw['message']?.toString().isNotEmpty==true?raw['message'].toString():'Pesan baru');syncFast();}
  void _onGroupMessage(dynamic raw){if(raw is! Map)return;final gid=raw['groupId']?.toString();final g=groupMap[gid];if(g==null)return;final sender=raw['senderUsername']?.toString()??'Anggota';final member=List<Map<String,dynamic>>.from((g['members'] as List? ?? const []).map((e)=>Map<String,dynamic>.from(e)));final row=member.where((m)=>m['username']?.toString()==sender).toList();final name=row.isNotEmpty?(row.first['name']??sender).toString():sender;_showBanner('$name • ${g['name']}');NotificationService.show(title:'$name • ${g['name']}',body:raw['message']?.toString().isNotEmpty==true?raw['message'].toString():'Pesan baru di grup');syncFast();}
  void _showBanner(String text){bannerTimer?.cancel();if(!mounted)return;setState(()=>bannerText=text);bannerTimer=Timer(const Duration(seconds:4),(){if(mounted)setState(()=>bannerText=null);});}
  void _clearBanner(){bannerTimer?.cancel();if(mounted)setState(()=>bannerText=null);}
  void _startPolling(){pollTimer?.cancel();pollTimer=Timer.periodic(const Duration(seconds:8),(_){if(!socket.connected){syncFast().whenComplete((){if(mounted&&!socket.connected)_connect();});}});}
  void _stopPolling(){pollTimer?.cancel();pollTimer=null;}
  @override void didPushNext(){_stopPolling();}
  @override void didPopNext(){_startPolling();syncFast();}
  Future<void> refresh()=>syncFast(forceLoading:true);
  Future<void> syncFast({bool forceLoading=false})async{if(syncing||widget.session.token==null)return;syncing=true;if(forceLoading&&mounted)setState(()=>loading=true);try{final data=await api.sync(widget.session.token!);await widget.session.updateUser(Map<String,dynamic>.from(data['user']??{}));final next=<String,Map<String,dynamic>>{};_mergeInto(next,data['contacts']);_mergeInto(next,data['inbox']);for(final e in next.entries){final marker=await LocalCache.readAt(e.key);final lastRaw=e.value['lastMessageAt']?.toString();final last=lastRaw==null?null:DateTime.tryParse(lastRaw)?.toUtc();if(marker!=null&&last!=null&&!last.isAfter(marker))e.value['unread']=0;}contactMap..clear()..addAll(next);final groups=<String,Map<String,dynamic>>{};if(data['groups'] is List){for(final raw in data['groups']){if(raw is Map&&raw['id']!=null)groups[raw['id'].toString()]=Map<String,dynamic>.from(raw);}}groupMap..clear()..addAll(groups);unreadTotal=contactMap.values.fold<int>(0,(s,c)=>s+_int(c['unread']))+groupMap.values.fold<int>(0,(s,g)=>s+_int(g['unread']));if(mounted)setState(()=>loading=false);}on ApiException catch(e){if(e.status==403)_showBanned();if(mounted)setState(()=>loading=false);}catch(_){if(mounted)setState(()=>loading=false);}finally{syncing=false;}}
  int _int(dynamic v)=>v is num?v.toInt():int.tryParse('$v')??0;
  void _mergeInto(Map<String,Map<String,dynamic>> target,dynamic raw){if(raw is! List)return;for(final item in raw){if(item is! Map)continue;final c=Map<String,dynamic>.from(item);final u=c['username']?.toString();if(u==null||u.isEmpty)continue;target[u]={...?target[u],...c};}}
  void _showBanned(){if(!mounted)return;_stopPolling();Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder:(_)=>BannedPage(session:widget.session)),(_)=>false);}
  Future<void> _openProfile(Map<String,dynamic> c)async{await Navigator.push(context,MaterialPageRoute(builder:(_)=>ContactProfilePage(session:widget.session,user:c)));}
  Future<void> _addMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF10171A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (c) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.person_add_alt_1_rounded),
              title: const Text('Tambah kontak'),
              onTap: () => Navigator.pop(c, 'contact'),
            ),
            ListTile(
              leading: const Icon(Icons.group_add_rounded),
              title: const Text('Grup baru'),
              onTap: () => Navigator.pop(c, 'group'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'contact') {
      final ok = await Navigator.push(context, MaterialPageRoute(builder: (_) => AddContactPage(session: widget.session)));
      if (!mounted) return;
      if (ok == true) {
        refresh();
      }
    } else if (choice == 'group') {
      final g = await Navigator.push(context, MaterialPageRoute(builder: (_) => CreateGroupPage(session: widget.session)));
      if (!mounted) return;
      if (g != null) {
        refresh();
      }
    }
  }
  @override void dispose(){_stopPolling();bannerTimer?.cancel();socket.disconnect();if(routeSubscribed)chatWithURouteObserver.unsubscribe(this);super.dispose();}
  @override Widget build(BuildContext context){final contacts=contactMap.values.where((c){final t='${c['name']??''} ${c['displayName']??''} ${c['username']??''}'.toLowerCase();return t.contains(search);}).toList()..sort((a,b)=>(b['lastMessageAt']??'').toString().compareTo((a['lastMessageAt']??'').toString()));final groups=groupMap.values.where((g)=>g['name'].toString().toLowerCase().contains(search)).toList()..sort((a,b)=>(b['lastMessageAt']??'').toString().compareTo((a['lastMessageAt']??'').toString()));return Scaffold(backgroundColor:const Color(0xFF080D10),appBar:AppBar(backgroundColor:const Color(0xFF080D10),elevation:0,titleSpacing:16,title:Row(children:[Container(width:40,height:40,decoration:BoxDecoration(borderRadius:BorderRadius.circular(13),gradient:const LinearGradient(colors:[Color(0xFF6C4DFF),Color(0xFF20C76B)])),child:const Icon(Icons.forum_rounded,size:22)),const SizedBox(width:10),const Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('X Chat',style:TextStyle(fontSize:19,fontWeight:FontWeight.w900)),Text('Private • Realtime',style:TextStyle(fontSize:10,color:Colors.white54))])]),actions:[IconButton(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>ProfilePage(session:widget.session))).then((_)=>refresh()),icon:const Icon(Icons.account_circle_outlined,size:27))]),body:Column(children:[if(unreadTotal>0)_UnreadBanner(count:unreadTotal)else if(bannerText!=null)_NotificationBanner(text:bannerText!,onClose:_clearBanner),Padding(padding:const EdgeInsets.fromLTRB(14,6,14,8),child:TextField(onChanged:(v)=>setState(()=>search=v.toLowerCase()),decoration:InputDecoration(hintText:tab==0?'Cari teman atau username':'Cari grup',prefixIcon:const Icon(Icons.search_rounded),filled:true,fillColor:const Color(0xFF171F23),border:OutlineInputBorder(borderRadius:BorderRadius.circular(20),borderSide:BorderSide.none)))),Container(margin:const EdgeInsets.fromLTRB(14,2,14,8),padding:const EdgeInsets.all(4),decoration:BoxDecoration(color:const Color(0xFF11191D),borderRadius:BorderRadius.circular(18)),child:Row(children:[_tabButton('Chat',0,Icons.chat_bubble_outline_rounded),_tabButton('Grup',1,Icons.groups_2_outlined)])),Expanded(child:loading?const Center(child:CircularProgressIndicator()):RefreshIndicator(onRefresh:refresh,child:tab==0?_chatList(contacts):_groupList(groups))) ]),floatingActionButton:FloatingActionButton(backgroundColor:Colors.white,foregroundColor:Colors.black,onPressed:_addMenu,child:const Icon(Icons.add)));}
  Widget _tabButton(String label,int index,IconData icon)=>Expanded(child:InkWell(borderRadius:BorderRadius.circular(14),onTap:()=>setState(()=>tab=index),child:Container(padding:const EdgeInsets.symmetric(vertical:10),decoration:BoxDecoration(color:tab==index?const Color(0xFF263036):Colors.transparent,borderRadius:BorderRadius.circular(14)),child:Row(mainAxisAlignment:MainAxisAlignment.center,children:[Icon(icon,size:17),const SizedBox(width:7),Text(label,style:TextStyle(fontWeight:tab==index?FontWeight.w800:FontWeight.w600))]))));
  Widget _chatList(List<Map<String,dynamic>> list)=>list.isEmpty?const Center(child:Text('Belum ada chat',style:TextStyle(color:Colors.white54))):ListView.builder(physics:const AlwaysScrollableScrollPhysics(),itemCount:list.length,itemBuilder:(_,i)=>_chatTile(list[i]));
  Widget _groupList(List<Map<String,dynamic>> list)=>list.isEmpty?const Center(child:Text('Belum ada grup',style:TextStyle(color:Colors.white54))):ListView.builder(physics:const AlwaysScrollableScrollPhysics(),itemCount:list.length,itemBuilder:(_,i)=>_groupTile(list[i]));
  Widget _chatTile(Map<String,dynamic> c){final u=(c['username']??'').toString();final name=(c['name']??c['displayName']??u).toString();final avatar=(c['avatarUrl']??'').toString();final verified=c['verified']==true;final unread=_int(c['unread']);return Container(margin:const EdgeInsets.symmetric(horizontal:10,vertical:3),decoration:BoxDecoration(color:const Color(0xFF10171A),borderRadius:BorderRadius.circular(18),border:Border.all(color:Colors.white.withValues(alpha:.035))),child:ListTile(contentPadding:const EdgeInsets.symmetric(horizontal:12,vertical:5),leading:GestureDetector(onTap:()=>_openProfile(c),child:Hero(tag:'profile-$u',child:CircleAvatar(radius:27,backgroundColor:const Color(0xFF2A1D38),backgroundImage:avatar.isNotEmpty?NetworkImage(avatar):null,child:avatar.isEmpty?Text(name.isEmpty?'?':name[0].toUpperCase(),style:const TextStyle(fontWeight:FontWeight.w800)):null))),title:Row(children:[Flexible(child:Text(name,style:const TextStyle(fontWeight:FontWeight.w800),overflow:TextOverflow.ellipsis)),if(verified)const Padding(padding:EdgeInsets.only(left:5),child:VerifiedBadge())]),subtitle:Padding(padding:const EdgeInsets.only(top:4),child:Text(c['lastMessage']?.toString().isNotEmpty==true?c['lastMessage'].toString():'@$u',maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Colors.white54))),trailing:Column(mainAxisAlignment:MainAxisAlignment.center,crossAxisAlignment:CrossAxisAlignment.end,children:[Text(c['lastMessageAt']!=null?_listTime(c['lastMessageAt']):'',style:TextStyle(fontSize:11,color:unread>0?const Color(0xFF20C76B):Colors.white38)),if(unread>0)Padding(padding:const EdgeInsets.only(top:3),child:_badge(unread))]),onTap:()async{c['unread']=0;await Navigator.push(context,MaterialPageRoute(builder:(_)=>ChatPage(session:widget.session,contact:c)));await refresh();}));}
  Widget _groupTile(Map<String,dynamic> g){final name=g['name'].toString();final members=List<dynamic>.from(g['members']??const []);final unread=_int(g['unread']);return Container(margin:const EdgeInsets.symmetric(horizontal:10,vertical:3),decoration:BoxDecoration(color:const Color(0xFF10171A),borderRadius:BorderRadius.circular(18)),child:ListTile(contentPadding:const EdgeInsets.symmetric(horizontal:12,vertical:6),leading:CircleAvatar(radius:27,backgroundColor:const Color(0xFF2D2039),child:Text(name.isEmpty?'?':name[0].toUpperCase(),style:const TextStyle(fontWeight:FontWeight.w800))),title:Text(name,style:const TextStyle(fontWeight:FontWeight.w800)),subtitle:Padding(padding:const EdgeInsets.only(top:4),child:Text(g['lastMessage']?.toString().isNotEmpty==true?g['lastMessage'].toString():'${members.length} anggota',maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Colors.white54))),trailing:unread>0?_badge(unread):Text(g['lastMessageAt']!=null?_listTime(g['lastMessageAt']):'',style:const TextStyle(fontSize:11,color:Colors.white38)),onTap:()async{await Navigator.push(context,MaterialPageRoute(builder:(_)=>GroupChatPage(session:widget.session,group:g)));await refresh();}));}
  Widget _badge(int n)=>Container(padding:const EdgeInsets.symmetric(horizontal:7,vertical:4),decoration:BoxDecoration(color:const Color(0xFF20C76B),borderRadius:BorderRadius.circular(10)),child:Text(n>99?'99+':'$n',style:const TextStyle(color:Colors.black,fontSize:10,fontWeight:FontWeight.w900)));
  String _listTime(dynamic value){final d=DateTime.tryParse(value.toString())?.toLocal();if(d==null)return'';final n=DateTime.now();final diff=DateTime(n.year,n.month,n.day).difference(DateTime(d.year,d.month,d.day)).inDays;if(diff==0)return'${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';if(diff==1)return'Kemarin';return'${d.day.toString().padLeft(2,'0')}/${d.month.toString().padLeft(2,'0')}';}
}
class _NotificationBanner extends StatelessWidget{final String text;final VoidCallback onClose;const _NotificationBanner({required this.text,required this.onClose});@override Widget build(BuildContext context)=>Material(color:const Color(0xFF1E3B31),child:InkWell(onTap:onClose,child:Padding(padding:const EdgeInsets.symmetric(horizontal:16,vertical:11),child:Row(children:[const Icon(Icons.notifications_active_outlined,size:20),const SizedBox(width:10),Expanded(child:Text(text,style:const TextStyle(fontWeight:FontWeight.w600))),IconButton(onPressed:onClose,icon:const Icon(Icons.close,size:18))]))));}
class _UnreadBanner extends StatelessWidget{final int count;const _UnreadBanner({required this.count});@override Widget build(BuildContext context)=>Material(color:const Color(0xFF1E3B31),child:Padding(padding:const EdgeInsets.symmetric(horizontal:16,vertical:10),child:Row(children:[const Icon(Icons.mark_chat_unread_rounded,size:20),const SizedBox(width:10),Expanded(child:Text('$count pesan belum dibaca',style:const TextStyle(fontWeight:FontWeight.w700))),const Icon(Icons.chevron_right_rounded,size:20)])));}
