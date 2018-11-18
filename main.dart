// BUG: Calendar doesn't maintain the current day, add a global variable for that
  // cal --> day
  // more --> today
  // today --> today
  // startup --> today
  // add the button
// TODO: Upgrade infrastructure to Firebase (already imported)
// BUG: Only update marker on successful update
// TODO: Add self-update button
// TODO: Add spiner dialog during download
// TODO: Use Firebase OCR (from TensorFLow) to read schedule
  // send notifications on new class, room
  // Find optimal UX for displaying current class, room on startup

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import "package:image_picker/image_picker.dart";
import "package:fluttertoast/fluttertoast.dart";
import "package:http/http.dart" as internet;
import "package:flutter/services.dart";
import "package:path_provider/path_provider.dart";
import "package:url_launcher/url_launcher.dart";
import "package:firebase_storage/firebase_storage.dart";

import "dart:async";
import "dart:io";

final DateTime now = DateTime.now();
final Map <String, String> gDriveIds = {
  "calendar": "0B6O0FTIKlHJiemFFNGZKYnBjZ0k",
  "calendarUpdate": "16u3iDWnzmXB_8bKnLmzZJeNHybPi_0Vd",
  "picsUpdate": "1eT40K_Vdsgn6KyUBI6zcs56UkzCxRaiA",
  "selfUpdate": "1xAPLd-znXjj78XdT02pJUmvrJC5j5fdA",
  "self": "1Q0En00Tg3cnhND5aSU036Sqhk9kadRmx"
};
final Map <String, String> specialUrls = {
  "Rosh Chodesh": "1gVg5lZxkZ327FGikajrTULYXjFEQ_ZFP",
  "Fast Day": "10qdwQ6njFcmn-BqYphTJuvyWpa23kBWx",
  "Friday": "1W3endUgsO07WD1jEsrmVDxUFn1BqhDhU",
  "Friday Rosh Chodesh": "1n4zdwHgn-TmlWfiMTVeBe3Wn3WutZGBc",
  "Winter Friday": "19Jptc2qaeVUvpuYU2cMWDJMRXO35Bbeh",
  "Winter Friday Rosh Chodesh": "1ycL097206unfi71ZRoTyI01LdYzoKR50",
  "Morning Assembly": "1XArdqS4yJBM7kG4akOAzYH8yt4XEbLeL",
  "Afternoon Assembly": "1vPkB6az8WyOFMzgNG4nWeYOYrwP4Gnn9",
  "A, B, or C day": "1IZlXz8qon8bXHhYPBC8a2-Yq3WSt254H",
  "M or R day": "1smxcWdVti97Ugsn63GuWUI-LRDIHukJ_",
  "Early": "1khtZwdSi7Op3k4mYjD1-2d3dM3c_eemx"
};
final List <String> letters = ["A", "B", "C", "E", "F", "M", "R"];
final List <String> specials = [
  "Rosh Chodesh",
  "Fast Day",
  "Friday",
  "Friday Rosh Chodesh",
  "Winter Friday",
  "Winter Friday Rosh Chodesh",
  "Morning Assembly",
  "Afternoon Assembly",
  "M or R day",
  "A, B, or C day",
  "Early",
  "Modified",
];
List <int> daysInMonths = [
  31, //January
  29, //February (just to be safe!)
  31, //March
  30, //April
  31, //May
  30, //June
  31, //July
  31, //August
  30, //September
  31, //October
  30, //November
  31  //December
];
final int today = now.day;

SharedPreferences prefs;
Map <String, String> imgPaths = {};
Map <String, String> specialPaths = {};
List <String> calendar, backup;
String dir, specialDownloadError;
bool fatalError = false, updatedCalendar = false, selfUpdate = false;
bool calendarOutdated, calendarCorrupted, backedUp;
DateTime currentDate = now;

void main () async {
  // setup
  await SystemChrome.setPreferredOrientations ([DeviceOrientation.portraitUp]);
  getApplicationDocumentsDirectory().then ((uri) {dir = uri.path;});
  prefs = await SharedPreferences.getInstance();

  // retrieve the calendar
  try {await getCalendar (download: false);}
  catch (readError) { //need to download
    print ("MAIN: Calendar not found. Attempting download...");
    try {await getCalendar (download: true, important: true);}
    catch (internetError) {
      print ("MAIN: Download failed! Setting fatalError to true.");
      fatalError = true;
      prefs.setString ("underlyingError", "fatal");
    }
  }
  assert (calendar != null, "MAIN: Calendar is null");

  // retrieve images
  bool setupNeeded = !getImagesReady();
  if (!setupNeeded) {
    List <String> paths = prefs.getStringList ("imgPaths");
    for (int index = 0; index < letters.length; index++) {
      String letter = letters [index];
      String path = paths [index];
      imgPaths [letter] = path;
    }
  }
  getSpecialPics();

  // check for updates
  specialDownloadError = prefs.getString ("downloadError");
  getUpdate ("calendar", firstTime: true);
  getUpdate ("self", firstTime: true);
  getUpdate ("pics", firstTime: true);

  getUpdateFirebase();

  // verify calendar
  calendarOutdated = getCalendarOutdated();
  try {calendarCorrupted = !getCalendarReady();}
  catch (technicalError) {
    print ("MAIN: TECHNICAL ERROR --> CALENDAR CORRUPTED.");
    calendarCorrupted = true;
    rethrow;
  }
  if (calendarCorrupted || calendarOutdated || fatalError) {
    print ("MAIN: Something was wrong with the calendar, trying again...");
    try {await getCalendar (download: true, important: true);} 
    catch (error) {} //Nothing to do...
  }
  if (calendarOutdated) prefs.setString ("underlyingError", "outdated");
  if (calendarCorrupted) prefs.setString ("underlyingError", "corrupted");

  // start
  runApp (
    MaterialApp (
      title: "Schedule Tracker",
      home: setupNeeded ? SetupStepper() : ScheduleApp(),
      routes: <String, WidgetBuilder> {
        "/setup": (BuildContext _) => SetupStepper(),
        "/main": (BuildContext _) => ScheduleApp()
      }
    ) 
  );
}

// updates
void getSpecialUpdate() async {
  for (String special in specials) {
    if (special == "Modified") continue;
    getInternetImage (specialUrls [special], special);
  }
}

void getUpdate (String component, {bool firstTime = false}) {
  getInternetFile (gDriveIds [component + "Update"])
    .then ((value) {onGotUpdate (value, component, !firstTime);})
    .catchError ((error) {onInternetError (error, firstTime);});
}

bool getCalendarOutdated () {
  String lastDate = prefs.getString("lastCalendarUpdate")
    ?? "${now.month}/$today/${now.year}";
  List <String> lastDatesAsString = lastDate.split ("/");
  List <int> lastDates = lastDatesAsString.map(
    (value) => int.parse (value)
  ).toList ();
  int lastMonth = lastDates [0];
  int lastDay = lastDates [1];
  int lastYear = lastDates [2];
  DateTime lastUpdate = DateTime.utc (lastYear, lastMonth, lastDay);
  return now.difference(lastUpdate) > Duration (days: 7); //over a week ago
}

void getUpdateFirebase() async {
  StorageReference ref = FirebaseStorage.instance.ref().child ("schedule.csv");
  String url = (await ref.getDownloadURL()).toString;
  print (url);
}

// verifying
bool getImagesReady () {
  bool prefInput = prefs.getBool ("finishedSetup") ?? false;
  List <String> paths = prefs.getStringList ("imgPaths") ?? null;
  bool finishedSetup = !(!prefInput || paths == null || paths.length != 7);
  prefs.setBool ("finishedSetup", finishedSetup);
  return finishedSetup;
}

bool getCalendarReady () {
  assert (calendar != null, "GET_CALENDAR_READY: Calendar is null!");
  for (String day in calendar) {
    int indexOfSpace = day.indexOf (" ");
    if (indexOfSpace == -1) {
      if (!letters.contains (day)) {
        print ("GET_CALENDAR_READY: $day is not one of the predetermined letters");
        return false;
      }
    } else {
      String dayLetter = day.substring (0, indexOfSpace);
      String daySpecial = day.substring (indexOfSpace + 1);
      if (
        dayLetter != "No" && !(
          letters.contains (dayLetter) &&
          specials.contains(daySpecial)
        )
      ) {
        print ("GET_CALENDAR_READY: $day cannot be processed.");
        return false;
      }
    }
  }
  if (calendar.length < daysInMonths [now.month - 1] && now.month != 2) {//exceptions for Feb and leap yrs.
    print ("GET_CALENDAR_READY: Calendar has ${calendar.length} entries for month ${now.month} which has ${daysInMonths [now.month - 1]}.");
    return false;
  }
  return true; // passed all the tests
}

List <String> getImagePaths () => letters.map (
  (String letter) => imgPaths [letter]
).toList();

List <String> getSpecialPaths() => specials.map (
  (String special) => specialPaths [special]
).toList();

// downloading
Future <String> getInternetFile (String id) => internet.read (
  "https://drive.google.com/uc?export=download&id=$id"
);

Future getCalendar ({bool download, bool important = false}) async {
  assert (download != null);
  if (download) {
    if (important)
      onGotCalendar (await getInternetFile (gDriveIds ["calendar"])); //now
    else
      getInternetFile (gDriveIds ["calendar"]).then (onGotCalendar); //later
  } else {
    calendar = prefs.getStringList ("calendar");
    if (calendar == null) throw Error();
  }
}

void getInternetImage (String url, String name) => internet.get (
    "https://drive.google.com/uc?export=download&id=$url"
  )
    .then ((request) {onGotInternetRequest (request, name);})
    .catchError ((internetError) {
      specialDownloadError = name;
      print ("GET_INTERNET_IMAGE.ERROR: Unable to download photo for $name.");
      prefs.setString ("downloadError", name);
      throw internetError;
    }); //procrastination!

void getSelfUpdate() async {
  String url = "https://drive.google.com/uc?export=download&id=${gDriveIds ["self"]}";
  Fluttertoast.showToast (
    msg: "Downloading",
    toastLength: Toast.LENGTH_LONG
  );
  prefs.setBool ("selfUpdated", true);
  await launch (url);
}

void onGotUpdate (String newMarker, String component, bool bypass) {
  if (component == "calendar") {
    int currentMonth = now.month;
    int currentYear = now.year;
    prefs.setString ("lastCalendarUpdate", "$currentMonth/$today/$currentYear");
  }
  String oldMarker = prefs.getString (component + "Update") ?? "FIRST TIME";

  bool download = (
    oldMarker == "FIRST TIME" && component != "self" || oldMarker != newMarker ||
    component == "pics" && specialDownloadError != null || component == "self" &&
    !(prefs.getBool ("selfUpdated") ?? true) || bypass
  );

  print ("ON_GOT_UPDATE: ${download ? 'U' : 'Not u'}pdating $component.");
  if (component == "calendar") getCalendar (download: download);
  if (download) {
    if (component == "self") {
      selfUpdate = true;
      prefs.setBool ("selfUpdated", false);
      getSelfUpdate();
    }
    else if (component == "pics") getSpecialUpdate();
  } 
  prefs.setString (component + "Update", newMarker);
}

void onGotCalendar (String calendarAsCSV) {
  print ("ON_GOT_CALENDAR: Download complete.");
  calendar = calendarAsCSV.split (",");
  prefs.setStringList("calendar", calendar);
  fatalError = false;
  updatedCalendar = true;
  calendarCorrupted = !getCalendarReady();
  calendarOutdated = false;
  prefs.setString ("underlyingError", "${calendarCorrupted ? "corrupted" : "none"}");
}

void onGotInternetRequest (internet.Response request, String name) {
  var bytes = request.bodyBytes;
  File file = File ("$dir/$name.jpg");
  file.writeAsBytes (bytes).then ((success) {onSavedImage (file.path, name);});
}

void onInternetError (error, bool ignoreError) {
  if (!ignoreError) updatedCalendar = null;
  else print ("No internet connection!");
  throw error;
}

// disk
void getSpecialPics() {
  List <String> imgs = prefs.getStringList("specialPaths");
  if (imgs == null) specialPaths = Map.fromIterable(
    specials,
    key: (special) => special,
    // value: (special) => "images/${nameToFile (special, toFile: true)}.jpg"
    value: (special) => "images/$special.jpg"
  );
  else {
    int index = 0;
    for (String path in imgs) {
      String special = specials [index];
      specialPaths [special] = path;
      index++;
    }
  }
}

Future setImage (String day) async {
  assert (specials.contains (day) || letters.contains (day));
  bool usingLetters = letters.contains (day);
  Fluttertoast.showToast (
    msg: "Select photo for $day${usingLetters ? ' day' : 's'}",
    toastLength: Toast.LENGTH_LONG
  );
  File img = await ImagePicker.pickImage (source: ImageSource.gallery);
  if (usingLetters) {
    imgPaths [day] = img.path;
    prefs.setStringList ("imgPaths", getImagePaths());
  } else {
    specialPaths [day] = img.path;
    prefs.setStringList ("specialPaths", getSpecialPaths());
  }
}

void onSavedImage (String path, String name) {
  specialPaths [name] = path;
  print ("ON_SAVED_IMAGE: Updated photo for $name.");
  prefs.setStringList("specialPaths", getSpecialPaths());
  if (specialDownloadError == name) {
    print ("Able to download the times for $name.");
    prefs.remove ("downloadError");
    specialDownloadError = null;
  }
}

// misc
List <DropdownMenuItem<String>> getDropdownMenuItems (List <String> days) => days.map (
  (String day) => DropdownMenuItem <String> (
    child: Text (day),
    value: day
  )
).toList();

class SetupStepper extends StatefulWidget {
  @override
  _SetupStepperState createState () => _SetupStepperState ();
}

class _SetupStepperState extends State <SetupStepper> {
  bool firstTime = true;
  int currentStep = 0;
  List <String> steps = ["each"] + letters;
  Map <String, bool> status = {};

  void setup () {
    for (String step in steps) {
      status [step + "Started"] = (step == "each");
      status [step + "Finished"] = false;
    }
    firstTime = false;
  }

  void onContinue (BuildContext context) {
    String letter = steps [currentStep];
    if (letter != "each") setImage (letter); //dont need to add a pic for the intro
    if (letter == "R") {//reached the end
      prefs.setBool("finishedSetup", true);
      Navigator.pushReplacementNamed(context, "/main");
    } else
      setState (() {
        String nextLetter = steps [currentStep + 1];
        status [letter + "Finished"] = true;
        status [nextLetter + "Started"] = true;
        currentStep++;
      });
  }

  List <Step> getSteps () {
    if (firstTime) setup();
    return steps.map (
      (String step) => Step (
        title: Text ("Choose a photo for $step day"),
        subtitle: step == "each" ? Text (
          "I need this to show you your schedule \n"
          "for each day. Take a minute to take \n"
          "pictures of all your schedules."
        ) : null,
        content: Text (""),
        isActive: status [step + "Started"],
        state: status [step + "Finished"]
          ? StepState.complete
          : StepState.indexed
      )
    ).toList();
  }

  @override
  Scaffold build (BuildContext context) => Scaffold (
    body: Stepper (
      onStepContinue: () {onContinue (context);},
      currentStep: currentStep,
      steps: getSteps()
    )
  );
}

class ScheduleApp extends StatefulWidget {
  @override
  _ScheduleAppState createState () => _ScheduleAppState();
}

class _ScheduleAppState extends State <ScheduleApp> {
  String currentLetter, currentSpecial;
  bool processed = false;

  Image specialImage (String path) => path.startsWith ("images/")
    ? Image.asset (path)
    : Image.file (File (path));
  
  void _setup (BuildContext context) {
    if (processed) return; //nothing can be done
    processed = true;
    String underlyingError = prefs.getString("underlyingError") ?? "none";
    if (underlyingError != "none") {
      String lastTimeFixed = prefs.getString ("lastTimeFixed")
        ?? "1/${today + 1}/18";
      List <String> details = lastTimeFixed.split ("/");
      assert (details.length == 3);
      int lastMonth = int.parse (details [0]);
      int lastDay = int.parse (details [1]);
      int lastYear = int.parse (details [2]);
      if (lastMonth != now.month || lastYear != now.year || lastDay != today) {
        print ("SCHEDULE_APP.SETUP: $underlyingError error!");
        switch (underlyingError) {
          case "fatal": fatalError = true; break;
          case "outdated": calendarOutdated = true; break;
          case "corrupted": calendarCorrupted = true; break;
          default: throw ArgumentError (
            '"$underlyingError" is not one of: "fatal", "outdated", or "corrupted".'
          );
        }
      }
    } 
    if (specialDownloadError != null) Timer (
      Duration (milliseconds: 5000),
      () => specialDownloadError == null ? null : showDialog (
        context: context,
        builder: (BuildContext dialogContext) => SimpleDialog (
          title: Text ("Error updating photo of times"),
          children: [
            ListTile (
              subtitle: Text ("The picture that contains the times "
                "for ${specialDownloadError}s is outdated, and "
                "couldn't be updated! Either change it manually"
                " by swiping from the left side of the screen "
                "or wait for a better internet connection."
              )
            ),
            SimpleDialogOption (
              child: Text ("OK"),
              onPressed: () {Navigator.pop (dialogContext);}
            )
          ]
        )
      )
    );
    if (selfUpdate) Timer (
      Duration (milliseconds: 500),
      () => showDialog (
        context: context, 
        builder: (BuildContext dialogContext) => AlertDialog (
          title: Text ("Update App"),
          content: Text ("There is a new version of this app available"
            " to download. Click OK to download it. NOTE: You might"
            " need to select a Google account to access the update."
          ), 
          actions: [
            FlatButton (
              child: Text ("OK"),
              onPressed: () {
                Navigator.pop (dialogContext);
                getSelfUpdate();
              }
            ), 
            FlatButton (
              child: Text ("LATER"),
              onPressed: () => Navigator.pop (context)
            )
          ]
        )
      )
    );
    getCalendarOK (context);
    if (calendarCorrupted || fatalError) return;
    getSchedule (today - 1);
  }

  void showSnackbar (BuildContext context, {String message}) {
    assert (message != null);
    Timer (Duration (milliseconds: 500), () {
      Scaffold.of (context).showSnackBar (
        SnackBar (
          content: Text (message),
          duration: Duration (seconds: 1)
        )
      );
    });
  }

  bool getCalendarOK (BuildContext context) {
    if (fatalError) {
      onError (
        context: context,
        title: "Fatal Error!",
        message: "I was unable to read the calendar, or download a new one! "
          "I can't show the schedule of a specific day, but you can still "
          "manually select a day or try to download the calendar yourself."
      );
      return false;
    } else if (calendarCorrupted) {
      onError (
        context: context,
        title: "Calendar Corrupted!",
        message: "The calendar file is corrupt! Keep checking back every once "
          "in a while to see if the problem has been fixed. In the meantime, "
          "you can manually look at the days, or set today's date yourself."
      );
      return false;
    } else if (calendarOutdated) {
      onError (
        title: "Calendar may be outdated",
        message: "It's been over a week since I was last able to check for "
          "updates to the calendar. Consider manually re-downloading it or "
          "by ensuring a proper internet connection when you open the app. "
          "Also, you can manually set today's schedule.",
        context: context
      );
      return false;
    } else return true;
  }

  void getSchedule (int day) {
    String currentDay = calendar [day];
    int indexOfSpace = currentDay.indexOf (" ");
    if (indexOfSpace == -1) //no special
      setSchedule (letter: currentDay);
    else {
      String dayLetter = currentDay.substring (0, indexOfSpace);
      String daySpecial = currentDay.substring (indexOfSpace + 1);
      if (dayLetter == "No") setSchedule (letter: "No School");
      else {
        if (daySpecial == "None") setSchedule (letter: dayLetter);
        else setSchedule (letter: dayLetter, special: daySpecial);
      }
    }
  }

  void setTempSchedule (BuildContext context, {bool normal = false}) async {
    Navigator.pop (context);
    await showDialog (
      context: context,
      builder: (BuildContext _) => ErrorHandler (normal)
    );
    if (!(fatalError || calendarCorrupted)) { //allow undo
      print ("SET_TEMP_SCHEDULE: CurrentLetter: $currentLetter");
      print ("SET_TEMP_SCHEDULE: CurrentSpecial: $currentSpecial");
      backup = [currentLetter, currentSpecial];
      backedUp = true;
    }
    setState (() {
      processed = false;
    } );
  }

  void revertSchedule() {
    String backupLetter = backup [0];
    String backupSpecial = backup [1] ?? "";
    if (backupLetter == null) calendar [today - 1] = "No School";
    else if (backupSpecial == null) calendar [today - 1] = backupLetter;
    else calendar [today - 1] = "$backupLetter $backupSpecial";
    setState(() {processed = false;});
    prefs.setStringList("calendar", calendar);
  }

  String setSchedule ({String letter, String special}) {
    if (letter == "No School") {
      print ("SET_SCHEDULE: There is no school today");
      currentLetter = null;
      currentSpecial = null;
    } else {
      currentLetter = letter ?? currentLetter;
      currentSpecial = special;
      if (currentSpecial == null) {
        if (currentLetter == "M" || currentLetter == "R")
          currentSpecial = "M or R day";
        else if (["A", "B", "C"].contains (currentLetter))
          currentSpecial = "A, B, or C day";
      }
    }
    if (processed) setState(() {}); //avoid infinite loop w/ setup()
    return currentSpecial;
  }

  void onPressCalendar (BuildContext context) async {
    if (!getCalendarOK (context)) return;
    int currentYear = now.year;
    int currentMonth = now.month;
    int nextMonth = currentMonth + 1;
    int day = 1;
    DateTime firstInMonth = DateTime.utc (currentYear, currentMonth, day);
    DateTime firstDayNextMonth = DateTime.utc(currentYear, nextMonth, day);
    DateTime chosenDate = await showDatePicker (
      context: context,
      initialDate: now,
      firstDate: firstInMonth,
      lastDate: firstDayNextMonth
    );
    if (chosenDate == null) return;
    currentDate = chosenDate;
    int date = chosenDate.day - 1;
    getSchedule (date);
  }

  void onEditPhoto (String letter, BuildContext context) async {
    Navigator.pop (context);
    await setImage (letter);
    setState (() {});
  }

  void onEditSpecial (String special, BuildContext context) async {
    Navigator.pop (context);
    await setImage (special);
    setState((){});
  }

  void onError ({String title, String message, BuildContext context}) => Timer (
    Duration (milliseconds: 500),
    () {
      showDialog (
        context: context,
        builder: (BuildContext _) => AlertDialog (
          title: Text (title),
          content: ListTile (subtitle: Text (message)),
          actions: <Widget> [
            FlatButton (
              child: Text ("OK"),
              onPressed: () {Navigator.pop (context);}
            ),
            FlatButton (
              child: Text ("SET TODAY'S DATE"),
              onPressed: () {setTempSchedule (context);}
            )
          ]
        )
      );
    }
  );

  void onPressEditPhotos (BuildContext context, {bool regular}) {
    Navigator.pop (context);
    showModalBottomSheet (
      context: context,
      builder: (BuildContext builderContext) => Column (
        children: (regular ? letters : specials).map (
          (String day) => Expanded (
            child: FlatButton (
              child: Text ("$day${regular ? ' day' : ''}"),
              onPressed: () {
                if (regular) onEditPhoto (day, builderContext);
                else onEditSpecial (day, builderContext);
              }
            )
          )
        ).toList()
      )
    );
  }

  void onFixToday (BuildContext context) {
    if (fatalError || calendarCorrupted) {
      getCalendarOK (context);
      return;
    }
    showDialog (
      context: context,
      builder: (BuildContext _) => AlertDialog (
        title: Text ("Change today"),
        content: ListTile (
          subtitle: Text (
            "You can manually change today's date. Would you like to?"
          )
        ),
        actions: <Widget> [
          FlatButton (
            child: Text ("NO"),
            onPressed: () {Navigator.pop (context);}
          ),
          FlatButton (
            child: Text ("YES"),
            onPressed: () {setTempSchedule (context, normal: true);}
          )
        ]
      )
    );
  }

  void promptToChangeModified (BuildContext context) => Timer (
    Duration (milliseconds: 500),
    () => Scaffold.of(context).showSnackBar (
      SnackBar (
        content: Text ("Today is a modified day"),
        action: SnackBarAction (
          label: "Edit times",
          onPressed: () {setImage ("Modified"); setState((){});}
        ),
        duration: Duration (seconds: 1)
      )
    )
  );

  void addModified (List <Widget> contents, BuildContext context) {
    String file = specialPaths ["Modified"];
    if (file == null) {
      print ("ADD_MODIFIED: No modified image!");
      return;
    }
    contents.add (Expanded (child: specialImage (file)));
  }

  @override
  Widget build (BuildContext context) {
    if (currentLetter == "null") currentLetter = null; //idk
    if (currentSpecial == "null" || currentSpecial == "") 
      currentSpecial = null; //idc
    _setup (context);
    print ("BUILD: CurrentLetter: $currentLetter");
    print ("BUILD: CurrentSpecial: $currentSpecial");

    List <Widget> mainBody () {
      List <Widget> bodyContents = [SizedBox (width: 0.0, height: 1.0)];
      if (currentLetter != null) bodyContents.insert(
        0,
        Expanded (
          child: Image.file (File (imgPaths [currentLetter])),
        ),
      );
      if (currentSpecial == "Modified") addModified (bodyContents, context);
      else if (currentSpecial != null) bodyContents.add (
        Expanded (child: specialImage (specialPaths [currentSpecial])       ),
      );
      return bodyContents;
    }

    Builder body = Builder (
      builder: (BuildContext context) {
        if (fatalError)
          return Row (children: mainBody());
        if (updatedCalendar ?? false) {
          showSnackbar (context, message: "Updated calendar");
          updatedCalendar = false;
        } else if (updatedCalendar == null) {
          showSnackbar (context, message: "Calendar could not be updated");
          updatedCalendar = false;
        } else if (calendarCorrupted)
          showSnackbar (context, message: "Calendar could not be read");
        if (backedUp ?? false) {
          backedUp = false;
          Timer (
            Duration (milliseconds: 500),
            () {
              Scaffold.of(context).showSnackBar (
                SnackBar (
                  content: Text ("Changed today's date"),
                  action: SnackBarAction (
                    label: "Undo",
                    onPressed: revertSchedule
                  ),
                  duration: Duration (seconds: 1)
                )
              );
            }
          );
        } 
        if (currentSpecial == "Modified") promptToChangeModified (context);
        String message;
        if (currentLetter == null) message = "There is no school today";
        else message = "$currentLetter day";
        if (currentSpecial != null)
          message += ", $currentSpecial";
        showSnackbar (context, message: message);
        return Row (children: mainBody());
      }
    );

    Scaffold scaffold = Scaffold (
      appBar: AppBar (
        title: Text ("Schedule Tracker"),
        actions: <Widget> [
          IconButton (
            icon: Icon (Icons.edit),
            tooltip: "Edit today",
            onPressed: () {onFixToday (context);}
          ),
          IconButton (
            icon: Icon (Icons.date_range),
            tooltip: "Search by day",
            onPressed: () {onPressCalendar (context);}
          ),
          PopupMenuButton (
            icon: Icon (Icons.more_vert),
            onSelected: (_) {Navigator.pop (context);},
            itemBuilder: (BuildContext _) => <PopupMenuEntry> [
              PopupMenuItem (
                child: DayPicker (
                  "letters", 
                  currentLetter, 
                  this
                )
              ),
              PopupMenuItem (
                child: DayPicker (
                  "specials", 
                  currentSpecial, 
                  this
                )
              )
            ]
          )   
        ]
      ),

      floatingActionButton: FloatingActionButton (
        child: Icon (Icons.today),
        onPressed: () {
          if (!getCalendarOK (context)) return;
          currentDate = now;
          getSchedule (today - 1);
        },
        tooltip: "View today"
      ),

      body: body,

      drawer: Drawer (
        child: Column (
          children: <Widget> [
            DrawerHeader (
              child: Center (
                child: Text (
                  "Settings",
                  style: TextStyle (
                    fontSize: 50.0,
                    color: Colors.pinkAccent
                  )
                )
              ),
              decoration: BoxDecoration (color: Colors.blue)
            ),
            ListTile (
              title: Text ("Download calendar file"),
              leading: Icon (Icons.file_download),
              onTap: () {
                Navigator.pop (context);
                getUpdate ("calendar");
                Timer (
                  Duration (milliseconds: 2500),
                  () {setState((){});}
                );
              }
            ),
            ListTile (
              title: Text ("Edit schedule photos"),
              leading: Icon (Icons.add_a_photo),
              onTap: () {onPressEditPhotos (context, regular: true);}
            ),
            ListTile (
              title: Text ("Edit special times"),
              leading: Icon (Icons.access_time),
              onTap: () {onPressEditPhotos (context, regular: false);}
            ),
            ListTile (
              title: Text ("Update special time photos"),
              leading: Icon (Icons.update),
              onTap: getSpecialUpdate
            ),
            Expanded (child: SizedBox (width: 0.0, height: 200.0)),
            Divider(),
            ListTile (
              title: Text ("Ramaz Schedule app"),
              subtitle: Text ("An app to keep track of the schedule"),
              leading: Icon (Icons.schedule)
            ),
            AboutListTile (
              child: Text ("About"),
              icon: Icon (Icons.info),
              aboutBoxChildren: <Widget> [
                ListTile (
                  leading: CircleAvatar (
                    backgroundImage: AssetImage ("images/me.jpg"),
                    radius: 40.0
                  ),
                  title: Text ("Ramaz Schedule Tracker"),
                  subtitle: Text ("\nCreated by Levi Lesches\n\nVersion 2.0")
                ),
              ]
            )
          ]
        )
      )
    );
    return scaffold;
  }
}

class ErrorHandler extends StatefulWidget {
  ErrorHandler ([this.normal = false]);
  final bool normal;

  @override
  ErrorHandlerState createState () => ErrorHandlerState();
}

class ErrorHandlerState extends State <ErrorHandler> {
  String letter, special;

  void onBackupDaySelected () {
    prefs.setString ("lastTimeFixed", "${now.month}/$today/${now.year}");
    List <String> newCalendar;
    // rewrite the calendar with just today's date
    if (special == "None") special = null;
    if (widget.normal) {
      newCalendar = calendar;
      newCalendar [today - 1] = letter;
      if (special != null) newCalendar [today - 1] += " $special";
      calendar = newCalendar;
    } else {
      int daysInMonth = daysInMonths [now.month - 1]; //How long our list will be
      List <String> newCalendar = [];
      for (int day = 1; day < (daysInMonth + 1); day++) {
        String daySchedule;
        if (day == today) {
          // daySchedule = "$letter ${special ?? ''}";
          daySchedule = letter;
          if (special != null) daySchedule += " $special";
        }
        else daySchedule = "No School";
        newCalendar.add (daySchedule);
      }
      if (calendarCorrupted) calendarCorrupted = false;
      if (fatalError) fatalError = false;
      calendar = newCalendar;
    }
    prefs.setStringList ("calendar", newCalendar);
    // id and fix the issue
    if (calendarOutdated) calendarOutdated = false;
    prefs.setString ("underlyingError", "none");
    Navigator.pop(context);
  }

  @override
  Widget build (BuildContext context) => SimpleDialog (
    title: Text ("Choose today's day"),
    children: <Widget> [
      DropdownButton <String> (
        hint: Text ("     Select letter"),
        onChanged: (value) {
          setState (() {letter = value;});
        },
        value: letter,
        items: getDropdownMenuItems (["No School"] + letters),
      ),
      DropdownButton <String> (
        hint: Text ("     Select special"),
        onChanged: (value) {
          setState (() {special = value;});
        },
        value: special,
        items: getDropdownMenuItems (["None"] + specials),
      ),
      SimpleDialogOption (
        child: Text ("DONE"),
        onPressed: (letter == null)
          ? null
          : () {onBackupDaySelected();}
      )
    ]
  );
}

class DayPicker extends StatefulWidget {
  DayPicker (this.category, this.starter, this.app);
  final String category, starter;
  final _ScheduleAppState app;
  
  @override
  _DayPickerState createState() => _DayPickerState();
}

class _DayPickerState extends State <DayPicker> {
  String value;
  List <DropdownMenuItem> elements;
  bool processed = false;
  bool usingLetters;

  void setup() {
    processed = true;
    value = widget.starter;
    usingLetters = widget.category == "letters";
    elements = getDropdownMenuItems (
      usingLetters ? letters : ["None"] + specials
    );
  }

  void onSelectValue (String selected) {
    if (selected == "None") return;
    currentDate = now;
    if (usingLetters) widget.app.setSchedule (letter: selected);
    else widget.app.setSchedule (special: selected);
    setState ( () {value = selected;} );
  }

  @override 
  Widget build (BuildContext context) {
    if (!processed) setup();
    return DropdownButton <String> (
      value: value,
      hint: Text ("Select letter"),
      onChanged: onSelectValue,
      items: elements
    );
  }
}