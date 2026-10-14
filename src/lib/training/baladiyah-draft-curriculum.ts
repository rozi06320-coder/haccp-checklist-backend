export const trainingLocales = ["en", "ar", "id", "hi", "fil"] as const;

export type TrainingLocale = (typeof trainingLocales)[number];
export type LocalizedText = Record<TrainingLocale, string>;
export type ProvenanceClassification =
  | "baladiyah_explicit"
  | "existing_training_supporting"
  | "internal_operational";

type FactPresentation =
  | "overview"
  | "key_point"
  | "step"
  | "warning"
  | "scenario"
  | "corrective_action";

type DraftFact = {
  fact_key: string;
  lesson_key: "overview" | "practical-photo-guide";
  presentation: FactPresentation;
  position: number;
  provenance_classification: ProvenanceClassification;
  text_i18n: LocalizedText;
};

type PhotoRequirement = {
  asset_key: string;
  purpose: string;
  lesson_key: "overview" | "practical-photo-guide";
  placement: string;
  alt_i18n: LocalizedText;
  approval_status: "needed";
};

type QuizOption = {
  option_key: string;
  text_i18n: LocalizedText;
};

type QuizQuestion = {
  stable_key: string;
  source_fact_keys: string[];
  prompt_i18n: LocalizedText;
  options: QuizOption[];
  correct_option_key: string;
  explanation_i18n: LocalizedText;
};

type ModuleSource = {
  stable_key: string;
  position: number;
  category_key: "hygiene" | "food_safety" | "operations";
  source_module_ids: string[];
  default_provenance_classification: ProvenanceClassification;
  title_i18n: LocalizedText;
  description_i18n: LocalizedText;
  lesson_objectives_i18n: {
    overview: LocalizedText;
    practical_photo_guide: LocalizedText;
    knowledge_check: LocalizedText;
  };
  practical_mode: "procedure" | "reference";
  facts: DraftFact[];
  photo_requirements: PhotoRequirement[];
  quiz_questions: QuizQuestion[];
};

const text = (en: string, ar: string, id: string, hi: string, fil: string): LocalizedText => ({
  en,
  ar,
  id,
  hi,
  fil,
});

const option = (option_key: string, text_i18n: LocalizedText): QuizOption => ({ option_key, text_i18n });

const sharedLessonTitles = {
  overview: text("Overview", "نظرة عامة", "Ikhtisar", "अवलोकन", "Pangkalahatang-ideya"),
  practical: text(
    "Practical Photo Guide",
    "دليل الصور العملي",
    "Panduan Foto Praktis",
    "व्यावहारिक फोटो गाइड",
    "Praktikal na Gabay sa Larawan",
  ),
  quiz: text("Knowledge Check", "اختبار المعرفة", "Cek Pengetahuan", "ज्ञान जांच", "Pagsusuri ng Kaalaman"),
};

const explicit = "baladiyah_explicit" as const;
const supporting = "existing_training_supporting" as const;

const modules: ModuleSource[] = [
  {
    stable_key: "personal-hygiene-health",
    position: 1,
    category_key: "hygiene",
    source_module_ids: ["personal-hygiene"],
    default_provenance_classification: explicit,
    title_i18n: text(
      "Personal Hygiene & Health",
      "النظافة الشخصية والصحة",
      "Kebersihan Pribadi & Kesehatan",
      "व्यक्तिगत स्वच्छता और स्वास्थ्य",
      "Personal na Kalinisan at Kalusugan",
    ),
    description_i18n: text(
      "Staff hygiene, active health cards, grooming, handwashing, and wound protection drawn from the current Training curriculum.",
      "نظافة العاملين والبطاقات الصحية السارية والمظهر وغسل اليدين وحماية الجروح كما وردت في منهج التدريب الحالي.",
      "Kebersihan staf, kartu kesehatan aktif, penampilan, cuci tangan, dan perlindungan luka dari kurikulum Pelatihan saat ini.",
      "वर्तमान प्रशिक्षण पाठ्यक्रम से स्टाफ स्वच्छता, सक्रिय स्वास्थ्य कार्ड, ग्रूमिंग, हाथ धोना और घाव की सुरक्षा।",
      "Kalinisan ng staff, aktibong health card, grooming, paghuhugas ng kamay, at proteksiyon sa sugat mula sa kasalukuyang kurikulum.",
    ),
    lesson_objectives_i18n: {
      overview: text(
        "Recognize the current curriculum requirements for staff health, uniform, grooming, and hygiene.",
        "التعرّف على متطلبات المنهج الحالي لصحة العاملين والزي والمظهر والنظافة.",
        "Mengenali persyaratan kurikulum saat ini untuk kesehatan staf, seragam, penampilan, dan kebersihan.",
        "स्टाफ स्वास्थ्य, वर्दी, ग्रूमिंग और स्वच्छता के वर्तमान पाठ्यक्रम नियमों को पहचानें।",
        "Kilalanin ang kasalukuyang mga tuntunin sa kalusugan, uniporme, grooming, at kalinisan ng staff.",
      ),
      practical_photo_guide: text(
        "Follow the source-supported handwashing sequence and identify correct wound protection.",
        "اتباع تسلسل غسل اليدين المدعوم بالمصدر والتعرّف على الحماية الصحيحة للجروح.",
        "Mengikuti urutan cuci tangan yang didukung sumber dan mengenali perlindungan luka yang benar.",
        "स्रोत-समर्थित हाथ धोने का क्रम अपनाएँ और घाव की सही सुरक्षा पहचानें।",
        "Sundin ang source-supported na paghuhugas ng kamay at tukuyin ang tamang proteksiyon sa sugat.",
      ),
      knowledge_check: text(
        "Check understanding of handwashing, hygiene triggers, and wound protection.",
        "التحقق من فهم غسل اليدين ومواقف وجوبه وحماية الجروح.",
        "Memeriksa pemahaman tentang cuci tangan, pemicu kebersihan, dan perlindungan luka.",
        "हाथ धोने, उसके आवश्यक अवसरों और घाव की सुरक्षा की समझ जाँचें।",
        "Suriin ang pag-unawa sa paghuhugas ng kamay, mga pagkakataong kailangan ito, at proteksiyon sa sugat.",
      ),
    },
    practical_mode: "procedure",
    facts: [
      {
        fact_key: "health-card-active",
        lesson_key: "overview",
        presentation: "key_point",
        position: 1,
        provenance_classification: explicit,
        text_i18n: text(
          "Kitchen, cashier, bar, and steward staff must hold an active Baladiyah Health Card; the current curriculum lists stool tests, chest X-ray, and typhoid/hepatitis A vaccination as periodic checks.",
          "يجب أن يحمل موظفو المطبخ والكاشير والبار والتنظيف بطاقة صحية بلدية سارية؛ ويذكر المنهج الحالي فحص البراز وأشعة الصدر وتطعيم التيفوئيد/التهاب الكبد A ضمن الفحوص الدورية.",
          "Staf dapur, kasir, bar, dan steward harus memiliki Kartu Kesehatan Baladiyah aktif; kurikulum saat ini mencantumkan tes feses, rontgen dada, serta vaksin tifoid/hepatitis A sebagai pemeriksaan berkala.",
          "किचन, कैशियर, बार और स्टीवर्ड स्टाफ के पास सक्रिय Baladiyah Health Card होना चाहिए; वर्तमान पाठ्यक्रम में मल जाँच, छाती का एक्स-रे और टाइफाइड/हेपेटाइटिस A टीकाकरण आवधिक जाँच के रूप में दिए गए हैं।",
          "Dapat may aktibong Baladiyah Health Card ang kitchen, cashier, bar, at steward staff; nakalista sa kasalukuyang kurikulum ang stool test, chest X-ray, at bakuna sa typhoid/hepatitis A bilang pana-panahong pagsusuri.",
        ),
      },
      {
        fact_key: "clean-uniform-grooming",
        lesson_key: "overview",
        presentation: "key_point",
        position: 2,
        provenance_classification: explicit,
        text_i18n: text(
          "Wear a clean work uniform from the restaurant locker, cover hair, use a beard net, keep nails short and unpolished, and remove operational jewelry.",
          "ارتدِ زي عمل نظيفاً من خزانة المطعم، وغطِّ الشعر، واستخدم شبكة اللحية، وحافظ على الأظافر قصيرة بلا طلاء، وأزل المجوهرات أثناء العمل.",
          "Kenakan seragam kerja bersih dari loker restoran, tutup rambut, gunakan beard net, jaga kuku pendek tanpa kuteks, dan lepaskan perhiasan saat bekerja.",
          "रेस्तरां लॉकर से साफ कार्य-वर्दी पहनें, बाल ढकें, बियर्ड नेट लगाएँ, नाखून छोटे और बिना पॉलिश रखें तथा काम के आभूषण हटाएँ।",
          "Magsuot ng malinis na work uniform mula sa locker, takpan ang buhok, gumamit ng beard net, panatilihing maiksi at walang polish ang kuko, at alisin ang alahas habang nagtatrabaho.",
        ),
      },
      {
        fact_key: "handwash-wet",
        lesson_key: "practical-photo-guide",
        presentation: "step",
        position: 1,
        provenance_classification: explicit,
        text_i18n: text(
          "Wet hands with warm running water at 38°C-43°C.",
          "بلّل اليدين بماء جارٍ دافئ بدرجة 38°C-43°C.",
          "Basahi tangan dengan air mengalir hangat pada 38°C-43°C.",
          "हाथों को 38°C-43°C के गर्म बहते पानी से गीला करें।",
          "Basain ang mga kamay sa maligamgam na dumadaloy na tubig na 38°C-43°C.",
        ),
      },
      {
        fact_key: "handwash-soap",
        lesson_key: "practical-photo-guide",
        presentation: "step",
        position: 2,
        provenance_classification: explicit,
        text_i18n: text(
          "Use antibacterial liquid soap, not bar soap.",
          "استخدم صابوناً سائلاً مضاداً للبكتيريا، وليس صابوناً صلباً.",
          "Gunakan sabun cair antibakteri, bukan sabun batang.",
          "एंटीबैक्टीरियल लिक्विड साबुन उपयोग करें, बार साबुन नहीं।",
          "Gumamit ng antibacterial liquid soap, hindi bar soap.",
        ),
      },
      {
        fact_key: "handwash-scrub",
        lesson_key: "practical-photo-guide",
        presentation: "step",
        position: 3,
        provenance_classification: explicit,
        text_i18n: text(
          "Scrub palms, backs of hands, between fingers, under nails, thumbs, and wrists for at least 20 seconds.",
          "افرك راحتي اليدين وظهرهما وبين الأصابع وتحت الأظافر والإبهامين والمعصمين لمدة لا تقل عن 20 ثانية.",
          "Gosok telapak, punggung tangan, sela jari, bawah kuku, ibu jari, dan pergelangan setidaknya 20 detik.",
          "हथेलियाँ, हाथों का पिछला भाग, उँगलियों के बीच, नाखूनों के नीचे, अंगूठे और कलाइयाँ कम से कम 20 सेकंड तक रगड़ें।",
          "Kuskusin ang palad, likod ng kamay, pagitan ng mga daliri, ilalim ng kuko, hinlalaki, at pulsuhan nang hindi bababa sa 20 segundo.",
        ),
      },
      {
        fact_key: "handwash-dry",
        lesson_key: "practical-photo-guide",
        presentation: "step",
        position: 4,
        provenance_classification: explicit,
        text_i18n: text(
          "Dry with a single-use paper towel or air dryer, then use the towel to turn off the tap.",
          "جفّف بمنشفة ورقية أحادية الاستخدام أو بمجفف الهواء، ثم استخدم المنشفة لإغلاق الصنبور.",
          "Keringkan dengan tisu sekali pakai atau pengering udara, lalu gunakan tisu untuk menutup keran.",
          "एक बार उपयोग होने वाले पेपर टॉवल या एयर ड्रायर से सुखाएँ, फिर नल बंद करने के लिए टॉवल का उपयोग करें।",
          "Patuyuin gamit ang single-use paper towel o air dryer, saka gamitin ang towel sa pagsara ng gripo.",
        ),
      },
      {
        fact_key: "handwash-triggers",
        lesson_key: "practical-photo-guide",
        presentation: "key_point",
        position: 5,
        provenance_classification: explicit,
        text_i18n: text(
          "Wash hands before a shift and after using the toilet, touching the face or hair, coughing or sneezing, handling raw food or waste, or touching cash or cashier devices.",
          "اغسل اليدين قبل الوردية وبعد استخدام دورة المياه أو لمس الوجه أو الشعر أو السعال أو العطس أو التعامل مع الطعام النيء أو النفايات أو لمس النقود أو أجهزة الكاشير.",
          "Cuci tangan sebelum shift dan setelah dari toilet, menyentuh wajah atau rambut, batuk atau bersin, menangani makanan mentah atau sampah, atau menyentuh uang maupun perangkat kasir.",
          "शिफ्ट से पहले और शौचालय उपयोग, चेहरा या बाल छूने, खाँसने या छींकने, कच्चा भोजन या कचरा सँभालने, अथवा नकद या कैशियर उपकरण छूने के बाद हाथ धोएँ।",
          "Maghugas ng kamay bago ang shift at pagkatapos gumamit ng palikuran, humawak sa mukha o buhok, umubo o bumahing, humawak ng hilaw na pagkain o basura, o humawak ng pera o cashier device.",
        ),
      },
      {
        fact_key: "protected-cut",
        lesson_key: "practical-photo-guide",
        presentation: "warning",
        position: 6,
        provenance_classification: explicit,
        text_i18n: text(
          "Treat cuts with antiseptic, cover them with a blue waterproof bandage, and protect them with disposable gloves.",
          "عالج الجروح بمطهر، وغطِّها بضماد أزرق مقاوم للماء، واحمِها بقفازات أحادية الاستخدام.",
          "Rawat luka dengan antiseptik, tutup dengan plester biru tahan air, dan lindungi dengan sarung tangan sekali pakai.",
          "कटे घाव पर एंटीसेप्टिक लगाएँ, नीली जलरोधक पट्टी से ढकें और डिस्पोज़ेबल दस्ताने से सुरक्षित करें।",
          "Lagyan ng antiseptic ang sugat, takpan ng asul na waterproof bandage, at protektahan gamit ang disposable gloves.",
        ),
      },
    ],
    photo_requirements: [
      {
        asset_key: "personal-hygiene-clean-uniform-ppe",
        purpose: "Show the source-supported clean uniform and grooming standard.",
        lesson_key: "overview",
        placement: "overview-hero",
        alt_i18n: text(
          "Restaurant employee in a clean work uniform with covered hair and no operational jewelry.",
          "موظف مطعم يرتدي زي عمل نظيفاً مع تغطية الشعر ومن دون مجوهرات أثناء العمل.",
          "Karyawan restoran memakai seragam kerja bersih, rambut tertutup, dan tanpa perhiasan kerja.",
          "साफ कार्य-वर्दी, ढके हुए बाल और बिना कार्य-आभूषण वाला रेस्तरां कर्मचारी।",
          "Restaurant employee na naka-malinis na work uniform, nakatakip ang buhok, at walang alahas sa trabaho.",
        ),
        approval_status: "needed",
      },
      {
        asset_key: "personal-hygiene-handwashing-stages",
        purpose: "Show the four source-supported handwashing stages.",
        lesson_key: "practical-photo-guide",
        placement: "procedure-steps",
        alt_i18n: text(
          "Hands being wetted, soaped, scrubbed, and dried in the required sequence.",
          "يدان يتم تبليلهما ووضع الصابون وفركهما وتجفيفهما بالتسلسل المطلوب.",
          "Tangan dibasahi, diberi sabun, digosok, dan dikeringkan sesuai urutan.",
          "आवश्यक क्रम में हाथ गीले करते, साबुन लगाते, रगड़ते और सुखाते हुए।",
          "Mga kamay na binabasa, sinasabon, kinukuskos, at pinatutuyo sa tamang pagkakasunod-sunod.",
        ),
        approval_status: "needed",
      },
      {
        asset_key: "personal-hygiene-protected-cut",
        purpose: "Show a cut protected as described by the current curriculum.",
        lesson_key: "practical-photo-guide",
        placement: "warning-card",
        alt_i18n: text(
          "Finger cut covered with a blue waterproof bandage under a disposable glove.",
          "جرح في الإصبع مغطى بضماد أزرق مقاوم للماء تحت قفاز أحادي الاستخدام.",
          "Luka jari ditutup plester biru tahan air di bawah sarung tangan sekali pakai.",
          "उँगली का घाव डिस्पोज़ेबल दस्ताने के नीचे नीली जलरोधक पट्टी से ढका हुआ।",
          "Sugat sa daliri na natatakpan ng asul na waterproof bandage sa ilalim ng disposable glove.",
        ),
        approval_status: "needed",
      },
    ],
    quiz_questions: [
      {
        stable_key: "handwash-scrub-time",
        source_fact_keys: ["handwash-scrub"],
        prompt_i18n: text(
          "What is the minimum active hand-scrubbing time?",
          "ما الحد الأدنى لمدة فرك اليدين فعلياً؟",
          "Berapa waktu minimum menggosok tangan secara aktif?",
          "हाथ सक्रिय रूप से रगड़ने का न्यूनतम समय क्या है?",
          "Ano ang minimum na oras ng aktibong pagkuskos ng kamay?",
        ),
        options: [
          option("a", text("10 seconds", "10 ثوانٍ", "10 detik", "10 सेकंड", "10 segundo")),
          option("b", text("20 seconds", "20 ثانية", "20 detik", "20 सेकंड", "20 segundo")),
          option("c", text("40 seconds", "40 ثانية", "40 detik", "40 सेकंड", "40 segundo")),
        ],
        correct_option_key: "b",
        explanation_i18n: text(
          "The current curriculum requires scrubbing all listed hand areas for at least 20 seconds.",
          "يشترط المنهج الحالي فرك جميع مناطق اليد المذكورة لمدة لا تقل عن 20 ثانية.",
          "Kurikulum saat ini mensyaratkan semua bagian tangan yang disebutkan digosok setidaknya 20 detik.",
          "वर्तमान पाठ्यक्रम में सूचीबद्ध सभी हाथ क्षेत्रों को कम से कम 20 सेकंड रगड़ना आवश्यक है।",
          "Kailangan sa kasalukuyang kurikulum na kuskusin ang lahat ng nakalistang bahagi ng kamay nang hindi bababa sa 20 segundo.",
        ),
      },
      {
        stable_key: "handwash-after-raw-food",
        source_fact_keys: ["handwash-triggers"],
        prompt_i18n: text(
          "What must happen after handling raw food?",
          "ما الذي يجب فعله بعد التعامل مع الطعام النيء؟",
          "Apa yang harus dilakukan setelah menangani makanan mentah?",
          "कच्चा भोजन सँभालने के बाद क्या करना चाहिए?",
          "Ano ang dapat gawin pagkatapos humawak ng hilaw na pagkain?",
        ),
        options: [
          option("a", text("Wipe hands on the apron", "مسح اليدين بالمريلة", "Lap tangan pada apron", "एप्रन पर हाथ पोंछें", "Punasan ang kamay sa apron")),
          option("b", text("Change only the apron", "تغيير المريلة فقط", "Ganti apron saja", "केवल एप्रन बदलें", "Palitan lamang ang apron")),
          option("c", text("Wash hands", "غسل اليدين", "Cuci tangan", "हाथ धोएँ", "Maghugas ng kamay")),
        ],
        correct_option_key: "c",
        explanation_i18n: text(
          "Handling raw food is one of the listed handwashing triggers.",
          "التعامل مع الطعام النيء من الحالات المذكورة التي تستوجب غسل اليدين.",
          "Menangani makanan mentah adalah salah satu pemicu cuci tangan yang tercantum.",
          "कच्चा भोजन सँभालना सूचीबद्ध हाथ धोने के अवसरों में से एक है।",
          "Ang paghawak ng hilaw na pagkain ay isa sa mga nakalistang dahilan para maghugas ng kamay.",
        ),
      },
      {
        stable_key: "protect-small-cut",
        source_fact_keys: ["protected-cut"],
        prompt_i18n: text(
          "How must a small cut be protected before food work?",
          "كيف يجب حماية الجرح الصغير قبل العمل بالطعام؟",
          "Bagaimana luka kecil harus dilindungi sebelum bekerja dengan makanan?",
          "भोजन कार्य से पहले छोटे घाव को कैसे सुरक्षित करना चाहिए?",
          "Paano dapat protektahan ang maliit na sugat bago humawak ng pagkain?",
        ),
        options: [
          option("a", text("Antiseptic, blue waterproof bandage, and disposable glove", "مطهر وضماد أزرق مقاوم للماء وقفاز أحادي الاستخدام", "Antiseptik, plester biru tahan air, dan sarung tangan sekali pakai", "एंटीसेप्टिक, नीली जलरोधक पट्टी और डिस्पोज़ेबल दस्ताना", "Antiseptic, asul na waterproof bandage, at disposable glove")),
          option("b", text("Dry tissue only", "منديل جاف فقط", "Tisu kering saja", "केवल सूखा टिश्यू", "Tuyong tissue lamang")),
          option("c", text("Leave it uncovered", "تركه من دون تغطية", "Biarkan terbuka", "खुला छोड़ दें", "Iwanang walang takip")),
        ],
        correct_option_key: "a",
        explanation_i18n: text(
          "The current curriculum specifies antiseptic, a blue waterproof bandage, and disposable gloves.",
          "يحدد المنهج الحالي استخدام المطهر والضماد الأزرق المقاوم للماء والقفازات أحادية الاستخدام.",
          "Kurikulum saat ini menentukan antiseptik, plester biru tahan air, dan sarung tangan sekali pakai.",
          "वर्तमान पाठ्यक्रम एंटीसेप्टिक, नीली जलरोधक पट्टी और डिस्पोज़ेबल दस्ताने निर्धारित करता है।",
          "Itinatakda ng kasalukuyang kurikulum ang antiseptic, asul na waterproof bandage, at disposable gloves.",
        ),
      },
    ],
  },
  {
    stable_key: "cleaning-sanitation",
    position: 2,
    category_key: "hygiene",
    source_module_ids: ["cleaning-sanitation"],
    default_provenance_classification: explicit,
    title_i18n: text("Cleaning & Sanitation", "التنظيف والتعقيم", "Pembersihan & Sanitasi", "सफाई और सैनिटेशन", "Paglilinis at Sanitasyon"),
    description_i18n: text(
      "Cleaning, sanitizing, chemical control, the three-compartment sink, air drying, and cloth color coding from the current Training curriculum.",
      "التنظيف والتعقيم وضبط المواد الكيميائية وحوض الأقسام الثلاثة والتجفيف الهوائي وترميز ألوان الأقمشة من منهج التدريب الحالي.",
      "Pembersihan, sanitasi, pengendalian bahan kimia, bak tiga kompartemen, pengeringan udara, dan kode warna kain dari kurikulum Pelatihan saat ini.",
      "वर्तमान प्रशिक्षण पाठ्यक्रम से सफाई, सैनिटेशन, रसायन नियंत्रण, तीन-कम्पार्टमेंट सिंक, हवा में सुखाना और कपड़े का रंग कोड।",
      "Paglilinis, sanitasyon, chemical control, three-compartment sink, air drying, at color coding ng pamunas mula sa kasalukuyang kurikulum.",
    ),
    lesson_objectives_i18n: {
      overview: text("Distinguish cleaning from sanitizing and recognize the current chemical-control rules.", "التمييز بين التنظيف والتعقيم والتعرّف على قواعد ضبط المواد الكيميائية الحالية.", "Membedakan pembersihan dari sanitasi dan mengenali aturan pengendalian bahan kimia saat ini.", "सफाई और सैनिटेशन में अंतर तथा वर्तमान रसायन-नियंत्रण नियम पहचानें।", "Ihiwalay ang paglilinis sa sanitasyon at kilalanin ang kasalukuyang chemical-control rules."),
      practical_photo_guide: text("Follow the wash, rinse, sanitize, and air-dry sequence.", "اتباع تسلسل الغسل والشطف والتعقيم والتجفيف الهوائي.", "Mengikuti urutan cuci, bilas, sanitasi, dan keringkan dengan udara.", "धोने, कुल्ला करने, सैनिटाइज़ करने और हवा में सुखाने का क्रम अपनाएँ।", "Sundin ang wash, rinse, sanitize, at air-dry na pagkakasunod-sunod."),
      knowledge_check: text("Check understanding of sanitizer concentration, sequence, and air drying.", "التحقق من فهم تركيز المعقم والتسلسل والتجفيف الهوائي.", "Memeriksa pemahaman tentang konsentrasi sanitizer, urutan, dan pengeringan udara.", "सैनिटाइज़र सांद्रता, क्रम और हवा में सुखाने की समझ जाँचें।", "Suriin ang pag-unawa sa sanitizer concentration, pagkakasunod-sunod, at air drying."),
    },
    practical_mode: "procedure",
    facts: [
      { fact_key: "food-contact-cleaning-frequency", lesson_key: "overview", presentation: "key_point", position: 1, provenance_classification: explicit, text_i18n: text("Clean and sanitize food-contact surfaces after use, when changing ingredients, or at least every 4 hours of continuous use.", "نظّف وعقّم الأسطح الملامسة للطعام بعد الاستخدام أو عند تغيير المكونات أو كل 4 ساعات على الأقل من الاستخدام المتواصل.", "Bersihkan dan sanitasi permukaan yang bersentuhan dengan makanan setelah digunakan, saat mengganti bahan, atau setidaknya setiap 4 jam penggunaan terus-menerus.", "खाद्य-संपर्क सतहों को उपयोग के बाद, सामग्री बदलते समय या लगातार उपयोग के कम से कम हर 4 घंटे में साफ और सैनिटाइज़ करें।", "Linisin at i-sanitize ang food-contact surfaces pagkatapos gamitin, kapag nagpapalit ng sangkap, o hindi bababa sa bawat 4 na oras ng tuloy-tuloy na paggamit.") },
      { fact_key: "chemical-storage", lesson_key: "overview", presentation: "warning", position: 2, provenance_classification: explicit, text_i18n: text("Detergents, degreasers, and chlorine or quats sanitizers require MSDS and locked storage away from food.", "تتطلب المنظفات ومزيلات الدهون ومعقمات الكلور أو الأمونيوم الرباعي نشرات MSDS وتخزيناً مقفلاً بعيداً عن الطعام.", "Deterjen, degreaser, dan sanitizer klorin atau quats memerlukan MSDS dan penyimpanan terkunci jauh dari makanan.", "डिटर्जेंट, डीग्रीज़र और क्लोरीन या क्वाट्स सैनिटाइज़र के लिए MSDS तथा भोजन से दूर बंद भंडारण आवश्यक है।", "Ang detergent, degreaser, at chlorine o quats sanitizer ay nangangailangan ng MSDS at nakakandadong imbakan na malayo sa pagkain.") },
      { fact_key: "sink-wash", lesson_key: "practical-photo-guide", presentation: "step", position: 1, provenance_classification: explicit, text_i18n: text("Wash in clean water with detergent at 43°C-49°C.", "اغسل في ماء نظيف مع منظف بدرجة 43°C-49°C.", "Cuci dalam air bersih dengan deterjen pada 43°C-49°C.", "43°C-49°C पर साफ पानी और डिटर्जेंट से धोएँ।", "Hugasan sa malinis na tubig na may detergent sa 43°C-49°C.") },
      { fact_key: "sink-rinse", lesson_key: "practical-photo-guide", presentation: "step", position: 2, provenance_classification: explicit, text_i18n: text("Rinse with warm, clean running water to remove soap residue.", "اشطف بماء جارٍ دافئ ونظيف لإزالة بقايا الصابون.", "Bilas dengan air mengalir hangat dan bersih untuk menghilangkan sisa sabun.", "साबुन के अवशेष हटाने के लिए गर्म साफ बहते पानी से कुल्ला करें।", "Banlawan sa maligamgam at malinis na dumadaloy na tubig upang alisin ang latak ng sabon.") },
      { fact_key: "sink-sanitize", lesson_key: "practical-photo-guide", presentation: "step", position: 3, provenance_classification: explicit, text_i18n: text("Sanitize with chlorine at 50-100 ppm or quats at 200-400 ppm for 30-60 seconds, or use hot water at least 77°C.", "عقّم بالكلور بتركيز 50-100 ppm أو بمركبات الأمونيوم الرباعية بتركيز 200-400 ppm لمدة 30-60 ثانية، أو استخدم ماءً ساخناً لا يقل عن 77°C.", "Sanitasi dengan klorin 50-100 ppm atau quats 200-400 ppm selama 30-60 detik, atau gunakan air panas setidaknya 77°C.", "30-60 सेकंड के लिए 50-100 ppm क्लोरीन या 200-400 ppm क्वाट्स से सैनिटाइज़ करें, अथवा कम से कम 77°C गर्म पानी उपयोग करें।", "I-sanitize gamit ang chlorine na 50-100 ppm o quats na 200-400 ppm sa loob ng 30-60 segundo, o gumamit ng mainit na tubig na hindi bababa sa 77°C.") },
      { fact_key: "air-dry", lesson_key: "practical-photo-guide", presentation: "step", position: 4, provenance_classification: explicit, text_i18n: text("Air dry equipment on stainless racks; do not dry it with a wiping cloth.", "جفّف المعدات بالهواء على رفوف ستانلس؛ ولا تجففها بقطعة مسح.", "Keringkan peralatan dengan udara di rak stainless; jangan keringkan dengan kain lap.", "उपकरण को स्टेनलेस रैक पर हवा में सुखाएँ; पोंछने वाले कपड़े से न सुखाएँ।", "Patuyuin sa hangin ang kagamitan sa stainless rack; huwag patuyuin gamit ang pamunas.") },
      { fact_key: "cloth-colors", lesson_key: "practical-photo-guide", presentation: "key_point", position: 5, provenance_classification: explicit, text_i18n: text("Use red cloths for toilets or waste, yellow for raw preparation, green for produce or dessert, and blue for service, cashier, or dining areas.", "استخدم القماش الأحمر لدورات المياه أو النفايات، والأصفر لتحضير النيء، والأخضر للخضار أو الحلوى، والأزرق لمناطق الخدمة أو الكاشير أو صالة الطعام.", "Gunakan kain merah untuk toilet atau sampah, kuning untuk persiapan bahan mentah, hijau untuk hasil bumi atau dessert, dan biru untuk area servis, kasir, atau ruang makan.", "लाल कपड़ा शौचालय या कचरे, पीला कच्ची तैयारी, हरा फल-सब्ज़ी या डेज़र्ट और नीला सेवा, कैशियर या डाइनिंग क्षेत्र के लिए उपयोग करें।", "Gamitin ang pulang pamunas sa palikuran o basura, dilaw sa raw preparation, berde sa produce o dessert, at asul sa service, cashier, o dining area.") },
    ],
    photo_requirements: [
      { asset_key: "cleaning-food-contact-surface", purpose: "Show a clean food-contact surface ready for sanitation.", lesson_key: "overview", placement: "overview-hero", alt_i18n: text("Clean food-contact work surface prepared for sanitation.", "سطح عمل نظيف ملامس للطعام ومجهز للتعقيم.", "Permukaan kerja bersih yang bersentuhan dengan makanan dan siap disanitasi.", "सैनिटेशन के लिए तैयार साफ खाद्य-संपर्क कार्य सतह।", "Malinis na food-contact work surface na handa para sa sanitasyon."), approval_status: "needed" },
      { asset_key: "cleaning-four-stage-sequence", purpose: "Show wash, rinse, sanitize, and air-dry stages.", lesson_key: "practical-photo-guide", placement: "procedure-steps", alt_i18n: text("Equipment moving through wash, rinse, sanitize, and air-dry stages.", "معدات تمر بمراحل الغسل والشطف والتعقيم والتجفيف الهوائي.", "Peralatan melalui tahap cuci, bilas, sanitasi, dan kering udara.", "उपकरण धोने, कुल्ला, सैनिटाइज़ और हवा में सुखाने के चरणों से गुजरता हुआ।", "Kagamitan na dumaraan sa wash, rinse, sanitize, at air-dry na mga yugto."), approval_status: "needed" },
      { asset_key: "cleaning-sanitizer-test", purpose: "Show sanitizer concentration being checked without implying an unapproved method.", lesson_key: "practical-photo-guide", placement: "sanitizer-reference", alt_i18n: text("Sanitizer concentration check displaying the approved range.", "فحص تركيز المعقم مع إظهار النطاق المعتمد.", "Pemeriksaan konsentrasi sanitizer yang menampilkan rentang yang disetujui.", "स्वीकृत सीमा दिखाती सैनिटाइज़र सांद्रता जाँच।", "Pagsusuri ng sanitizer concentration na nagpapakita ng aprubadong saklaw."), approval_status: "needed" },
      { asset_key: "cleaning-color-coded-cloths", purpose: "Show the four current cloth color assignments.", lesson_key: "practical-photo-guide", placement: "reference-card", alt_i18n: text("Red, yellow, green, and blue cleaning cloths separated by work area.", "أقمشة تنظيف حمراء وصفراء وخضراء وزرقاء مفصولة حسب منطقة العمل.", "Kain pembersih merah, kuning, hijau, dan biru dipisahkan berdasarkan area kerja.", "कार्य क्षेत्र के अनुसार अलग लाल, पीले, हरे और नीले सफाई कपड़े।", "Pula, dilaw, berde, at asul na cleaning cloth na hiwalay ayon sa work area."), approval_status: "needed" },
    ],
    quiz_questions: [
      {
        stable_key: "sanitizer-chlorine-range", source_fact_keys: ["sink-sanitize"],
        prompt_i18n: text("What chlorine range is listed for the sanitizing sink?", "ما نطاق الكلور المذكور لحوض التعقيم؟", "Berapa rentang klorin yang tercantum untuk bak sanitasi?", "सैनिटाइजिंग सिंक के लिए सूचीबद्ध क्लोरीन सीमा क्या है?", "Ano ang nakalistang chlorine range para sa sanitizing sink?"),
        options: [option("a", text("10-20 ppm", "10-20 ppm", "10-20 ppm", "10-20 ppm", "10-20 ppm")), option("b", text("50-100 ppm", "50-100 ppm", "50-100 ppm", "50-100 ppm", "50-100 ppm")), option("c", text("200-400 ppm", "200-400 ppm", "200-400 ppm", "200-400 ppm", "200-400 ppm"))],
        correct_option_key: "b",
        explanation_i18n: text("The current curriculum lists chlorine at 50-100 ppm.", "يذكر المنهج الحالي الكلور بتركيز 50-100 ppm.", "Kurikulum saat ini mencantumkan klorin 50-100 ppm.", "वर्तमान पाठ्यक्रम में क्लोरीन 50-100 ppm दिया गया है।", "Nakalista sa kasalukuyang kurikulum ang chlorine na 50-100 ppm."),
      },
      {
        stable_key: "three-sink-order", source_fact_keys: ["sink-wash", "sink-rinse", "sink-sanitize", "air-dry"],
        prompt_i18n: text("Which sequence matches the current curriculum?", "أي تسلسل يطابق المنهج الحالي؟", "Urutan mana yang sesuai dengan kurikulum saat ini?", "कौन-सा क्रम वर्तमान पाठ्यक्रम से मेल खाता है?", "Aling pagkakasunod-sunod ang tumutugma sa kasalukuyang kurikulum?"),
        options: [option("a", text("Rinse, wash, dry, sanitize", "شطف، غسل، تجفيف، تعقيم", "Bilas, cuci, keringkan, sanitasi", "कुल्ला, धोना, सुखाना, सैनिटाइज़", "Banlaw, hugas, tuyo, sanitize")), option("b", text("Wash, sanitize, rinse, towel dry", "غسل، تعقيم، شطف، تجفيف بالمنشفة", "Cuci, sanitasi, bilas, keringkan dengan kain", "धोना, सैनिटाइज़, कुल्ला, तौलिये से सुखाना", "Hugas, sanitize, banlaw, patuyuin ng pamunas")), option("c", text("Wash, rinse, sanitize, air dry", "غسل، شطف، تعقيم، تجفيف هوائي", "Cuci, bilas, sanitasi, kering udara", "धोना, कुल्ला, सैनिटाइज़, हवा में सुखाना", "Hugas, banlaw, sanitize, air dry"))],
        correct_option_key: "c",
        explanation_i18n: text("The listed sequence is wash, rinse, sanitize, then air dry.", "التسلسل المذكور هو الغسل ثم الشطف ثم التعقيم ثم التجفيف الهوائي.", "Urutan yang tercantum adalah cuci, bilas, sanitasi, lalu keringkan dengan udara.", "सूचीबद्ध क्रम धोना, कुल्ला, सैनिटाइज़ करना और फिर हवा में सुखाना है।", "Ang nakalistang pagkakasunod-sunod ay hugas, banlaw, sanitize, at saka air dry."),
      },
      {
        stable_key: "why-air-dry", source_fact_keys: ["air-dry"],
        prompt_i18n: text("How should sanitized equipment be dried?", "كيف يجب تجفيف المعدات المعقمة؟", "Bagaimana peralatan yang sudah disanitasi harus dikeringkan?", "सैनिटाइज़ किए गए उपकरण को कैसे सुखाना चाहिए?", "Paano dapat patuyuin ang na-sanitize na kagamitan?"),
        options: [option("a", text("With a reusable cloth", "بقطعة قماش قابلة لإعادة الاستخدام", "Dengan kain yang dapat digunakan kembali", "दोबारा उपयोग होने वाले कपड़े से", "Gamit ang reusable na pamunas")), option("b", text("By air drying on a stainless rack", "بالتجفيف الهوائي على رف ستانلس", "Dengan pengeringan udara di rak stainless", "स्टेनलेस रैक पर हवा में सुखाकर", "Sa air drying sa stainless rack")), option("c", text("With an apron", "بالمريلة", "Dengan apron", "एप्रन से", "Gamit ang apron"))],
        correct_option_key: "b",
        explanation_i18n: text("The current curriculum requires air drying and rejects wiping-cloth drying.", "يشترط المنهج الحالي التجفيف الهوائي ويرفض التجفيف بقطعة المسح.", "Kurikulum saat ini mensyaratkan pengeringan udara dan melarang pengeringan dengan kain lap.", "वर्तमान पाठ्यक्रम हवा में सुखाने की माँग करता है और कपड़े से सुखाने को मना करता है।", "Kailangan sa kasalukuyang kurikulum ang air drying at hindi ang pagpapatuyo gamit ang pamunas."),
      },
    ],
  },
  {
    stable_key: "contamination-foodborne-illness-prevention",
    position: 3,
    category_key: "food_safety",
    source_module_ids: ["food-contamination", "foodborne-illness"],
    default_provenance_classification: supporting,
    title_i18n: text(
      "Contamination & Foodborne Illness Prevention",
      "الوقاية من التلوث والأمراض المنقولة بالغذاء",
      "Pencegahan Kontaminasi & Penyakit Bawaan Makanan",
      "संदूषण और खाद्यजनित बीमारी की रोकथाम",
      "Pag-iwas sa Kontaminasyon at Foodborne Illness",
    ),
    description_i18n: text(
      "Hazard recognition, raw and ready-to-eat separation, illness exclusion, and time-temperature limits from the current Training curriculum.",
      "التعرّف على المخاطر وفصل الطعام النيء عن الجاهز للأكل واستبعاد المرضى وحدود الوقت والحرارة من منهج التدريب الحالي.",
      "Pengenalan bahaya, pemisahan bahan mentah dan siap santap, pembatasan staf sakit, serta batas waktu-suhu dari kurikulum Pelatihan saat ini.",
      "वर्तमान प्रशिक्षण पाठ्यक्रम से खतरे पहचानना, कच्चे और खाने के लिए तैयार भोजन को अलग रखना, बीमार कर्मचारी को हटाना और समय-तापमान सीमाएँ।",
      "Pagkilala sa hazard, paghihiwalay ng raw at ready-to-eat food, illness exclusion, at time-temperature limits mula sa kasalukuyang kurikulum.",
    ),
    lesson_objectives_i18n: {
      overview: text("Recognize contamination hazards, illness sources, and the current exclusion rule.", "التعرّف على مخاطر التلوث ومصادر المرض وقاعدة الاستبعاد الحالية.", "Mengenali bahaya kontaminasi, sumber penyakit, dan aturan pembatasan saat ini.", "संदूषण खतरों, बीमारी स्रोतों और वर्तमान निष्कासन नियम को पहचानें।", "Kilalanin ang contamination hazards, pinagmumulan ng sakit, at kasalukuyang exclusion rule."),
      practical_photo_guide: text("Compare safe separation and hazard-control examples without forcing a false procedure.", "مقارنة أمثلة الفصل الآمن وضبط المخاطر من دون فرض إجراء غير حقيقي.", "Membandingkan contoh pemisahan aman dan pengendalian bahaya tanpa memaksakan prosedur palsu.", "कृत्रिम प्रक्रिया बनाए बिना सुरक्षित पृथक्करण और खतरा नियंत्रण उदाहरणों की तुलना करें।", "Ihambing ang ligtas na paghihiwalay at hazard-control examples nang hindi gumagawa ng pekeng procedure."),
      knowledge_check: text("Check recognition of board colors, hazard types, and temperature limits.", "التحقق من معرفة ألوان ألواح التقطيع وأنواع المخاطر وحدود الحرارة.", "Memeriksa pengenalan warna talenan, jenis bahaya, dan batas suhu.", "कटिंग बोर्ड रंग, खतरे के प्रकार और तापमान सीमाओं की पहचान जाँचें।", "Suriin ang pagkilala sa board colors, hazard types, at temperature limits."),
    },
    practical_mode: "reference",
    facts: [
      { fact_key: "separate-raw-rte", lesson_key: "overview", presentation: "key_point", position: 1, provenance_classification: supporting, text_i18n: text("Keep raw products fully separated from cooked or ready-to-eat food.", "افصل المنتجات النيئة تماماً عن الطعام المطهو أو الجاهز للأكل.", "Pisahkan produk mentah sepenuhnya dari makanan matang atau siap santap.", "कच्चे उत्पादों को पके या खाने के लिए तैयार भोजन से पूरी तरह अलग रखें।", "Ganap na ihiwalay ang raw products sa cooked o ready-to-eat food.") },
      { fact_key: "biological-hazards", lesson_key: "practical-photo-guide", presentation: "key_point", position: 1, provenance_classification: supporting, text_i18n: text("Biological hazards include bacteria, viruses, fungi, parasites, and spores; the current curriculum uses Salmonella from raw poultry as an example.", "تشمل المخاطر البيولوجية البكتيريا والفيروسات والفطريات والطفيليات والأبواغ؛ ويستخدم المنهج الحالي السالمونيلا من الدواجن النيئة مثالاً.", "Bahaya biologis meliputi bakteri, virus, jamur, parasit, dan spora; kurikulum saat ini menggunakan Salmonella dari unggas mentah sebagai contoh.", "जैविक खतरों में बैक्टीरिया, वायरस, फफूँद, परजीवी और बीजाणु शामिल हैं; वर्तमान पाठ्यक्रम कच्ची पोल्ट्री से Salmonella को उदाहरण बनाता है।", "Kabilang sa biological hazards ang bacteria, virus, fungi, parasite, at spores; ginagamit ng kasalukuyang kurikulum ang Salmonella mula sa raw poultry bilang halimbawa.") },
      { fact_key: "chemical-hazards", lesson_key: "practical-photo-guide", presentation: "key_point", position: 2, provenance_classification: supporting, text_i18n: text("Chemical hazards include pesticide residue, cleaning chemicals, rust, and incorrectly stored chemicals.", "تشمل المخاطر الكيميائية بقايا المبيدات ومواد التنظيف والصدأ والمواد الكيميائية المخزنة بطريقة غير صحيحة.", "Bahaya kimia meliputi residu pestisida, bahan pembersih, karat, dan bahan kimia yang disimpan tidak benar.", "रासायनिक खतरों में कीटनाशक अवशेष, सफाई रसायन, जंग और गलत तरीके से रखे रसायन शामिल हैं।", "Kabilang sa chemical hazards ang pesticide residue, cleaning chemicals, kalawang, at maling nakaimbak na kemikal.") },
      { fact_key: "physical-hazards", lesson_key: "practical-photo-guide", presentation: "key_point", position: 3, provenance_classification: supporting, text_i18n: text("Physical hazards include hair, glass, staples, nails, and jewelry.", "تشمل المخاطر الفيزيائية الشعر والزجاج والدبابيس والمسامير والمجوهرات.", "Bahaya fisik meliputi rambut, kaca, staples, paku, dan perhiasan.", "भौतिक खतरों में बाल, काँच, स्टेपल, कील और आभूषण शामिल हैं।", "Kabilang sa physical hazards ang buhok, salamin, staple, pako, at alahas.") },
      { fact_key: "board-colors", lesson_key: "practical-photo-guide", presentation: "key_point", position: 4, provenance_classification: supporting, text_i18n: text("Use red for raw red meat, yellow for poultry, blue for seafood, green for produce, brown for cooked meat, and white for ready-to-eat food, dairy, or bread.", "استخدم الأحمر للحوم الحمراء النيئة، والأصفر للدواجن، والأزرق للمأكولات البحرية، والأخضر للخضار والفاكهة، والبني للحوم المطهوة، والأبيض للطعام الجاهز أو الألبان أو الخبز.", "Gunakan merah untuk daging merah mentah, kuning untuk unggas, biru untuk seafood, hijau untuk hasil bumi, cokelat untuk daging matang, dan putih untuk makanan siap santap, susu, atau roti.", "कच्चे लाल मांस के लिए लाल, पोल्ट्री के लिए पीला, समुद्री भोजन के लिए नीला, फल-सब्ज़ी के लिए हरा, पके मांस के लिए भूरा और खाने के लिए तैयार भोजन, डेयरी या ब्रेड के लिए सफेद उपयोग करें।", "Gamitin ang pula sa raw red meat, dilaw sa poultry, asul sa seafood, berde sa produce, kayumanggi sa cooked meat, at puti sa ready-to-eat food, dairy, o bread.") },
      { fact_key: "major-allergens", lesson_key: "practical-photo-guide", presentation: "key_point", position: 5, provenance_classification: supporting, text_i18n: text("The current curriculum lists milk, egg, peanuts or tree nuts, gluten, soy, fish, crustaceans, and sesame as major allergens.", "يذكر المنهج الحالي الحليب والبيض والفول السوداني أو المكسرات والغلوتين والصويا والأسماك والقشريات والسمسم ضمن مسببات الحساسية الرئيسية.", "Kurikulum saat ini mencantumkan susu, telur, kacang tanah atau kacang pohon, gluten, kedelai, ikan, krustasea, dan wijen sebagai alergen utama.", "वर्तमान पाठ्यक्रम दूध, अंडा, मूँगफली या ट्री नट्स, ग्लूटेन, सोया, मछली, क्रस्टेशियन और तिल को प्रमुख एलर्जेन बताता है।", "Nakalista sa kasalukuyang kurikulum ang gatas, itlog, peanut o tree nuts, gluten, soy, isda, crustaceans, at sesame bilang major allergens.") },
      { fact_key: "illness-exclusion", lesson_key: "overview", presentation: "warning", position: 2, provenance_classification: supporting, text_i18n: text("Apply exclusion or restriction before food work when staff have gastroenteritis symptoms.", "طبّق الاستبعاد أو التقييد قبل العمل بالطعام عندما تظهر على الموظف أعراض التهاب المعدة والأمعاء.", "Terapkan larangan atau pembatasan sebelum bekerja dengan makanan ketika staf memiliki gejala gastroenteritis.", "कर्मचारी में गैस्ट्रोएंटेराइटिस के लक्षण हों तो भोजन कार्य से पहले निष्कासन या प्रतिबंध लागू करें।", "Magpatupad ng exclusion o restriction bago humawak ng pagkain kapag may sintomas ng gastroenteritis ang staff.") },
      { fact_key: "pathogen-sources", lesson_key: "overview", presentation: "key_point", position: 3, provenance_classification: supporting, text_i18n: text("The current curriculum links Salmonella to raw poultry and eggs, E. coli to raw ground beef, contaminated produce, or unfiltered water, Staphylococcus aureus to staff wounds, nose, or mouth, and Norovirus to fecal-oral transmission and poor hand hygiene.", "يربط المنهج الحالي السالمونيلا بالدواجن والبيض النيء، والإشريكية القولونية باللحم المفروم النيء أو الخضار الملوثة أو الماء غير المصفى، والمكورات العنقودية الذهبية بجروح العامل أو أنفه أو فمه، والنوروفيروس بالانتقال البرازي الفموي وضعف نظافة اليدين.", "Kurikulum saat ini mengaitkan Salmonella dengan unggas dan telur mentah, E. coli dengan daging giling mentah, hasil bumi terkontaminasi, atau air tanpa filtrasi, Staphylococcus aureus dengan luka, hidung, atau mulut staf, serta Norovirus dengan penularan fekal-oral dan kebersihan tangan yang buruk.", "वर्तमान पाठ्यक्रम Salmonella को कच्ची पोल्ट्री और अंडों से, E. coli को कच्चे ग्राउंड बीफ, दूषित फल-सब्ज़ी या बिना फ़िल्टर पानी से, Staphylococcus aureus को कर्मचारी के घाव, नाक या मुँह से और Norovirus को मल-मुख संचरण तथा खराब हाथ स्वच्छता से जोड़ता है।", "Iniuugnay ng kasalukuyang kurikulum ang Salmonella sa raw poultry at itlog, E. coli sa raw ground beef, kontaminadong produce, o unfiltered water, Staphylococcus aureus sa sugat, ilong, o bibig ng staff, at Norovirus sa fecal-oral transmission at mahinang hand hygiene.") },
      { fact_key: "temperature-danger-zone", lesson_key: "overview", presentation: "warning", position: 4, provenance_classification: supporting, text_i18n: text("The Temperature Danger Zone is 5°C-60°C, and the current curriculum says TCS food must not remain there longer than 2 hours.", "منطقة خطر الحرارة هي 5°C-60°C، ويذكر المنهج الحالي أن طعام TCS يجب ألا يبقى فيها لأكثر من ساعتين.", "Temperature Danger Zone adalah 5°C-60°C, dan kurikulum saat ini menyatakan makanan TCS tidak boleh berada di sana lebih dari 2 jam.", "तापमान खतरा क्षेत्र 5°C-60°C है और वर्तमान पाठ्यक्रम कहता है कि TCS भोजन वहाँ 2 घंटे से अधिक नहीं रहना चाहिए।", "Ang Temperature Danger Zone ay 5°C-60°C, at sinasabi ng kasalukuyang kurikulum na hindi dapat manatili roon ang TCS food nang higit sa 2 oras.") },
      { fact_key: "symptom-free-return", lesson_key: "overview", presentation: "corrective_action", position: 5, provenance_classification: supporting, text_i18n: text("For the current vomiting and diarrhea scenario, the curriculum requires the employee to remain symptom-free for 24-48 hours before returning to food handling.", "في سيناريو القيء والإسهال الحالي، يشترط المنهج بقاء الموظف بلا أعراض لمدة 24-48 ساعة قبل العودة للتعامل مع الطعام.", "Untuk skenario muntah dan diare saat ini, kurikulum mensyaratkan karyawan bebas gejala selama 24-48 jam sebelum kembali menangani makanan.", "वर्तमान उल्टी और दस्त परिदृश्य में पाठ्यक्रम भोजन सँभालने पर लौटने से पहले कर्मचारी को 24-48 घंटे लक्षण-मुक्त रहने की आवश्यकता बताता है।", "Sa kasalukuyang senaryo ng pagsusuka at pagtatae, kailangan ng kurikulum na walang sintomas ang empleyado sa loob ng 24-48 oras bago bumalik sa food handling.") },
    ],
    photo_requirements: [
      { asset_key: "contamination-raw-rte-separation", purpose: "Compare safe and unsafe raw/RTE storage.", lesson_key: "practical-photo-guide", placement: "comparison-card", alt_i18n: text("Raw poultry stored below and separately from ready-to-eat food.", "دواجن نيئة مخزنة أسفل الطعام الجاهز للأكل ومنفصلة عنه.", "Unggas mentah disimpan di bawah dan terpisah dari makanan siap santap.", "कच्ची पोल्ट्री खाने के लिए तैयार भोजन के नीचे और अलग रखी हुई।", "Raw poultry na nakaimbak sa ibaba at hiwalay sa ready-to-eat food."), approval_status: "needed" },
      { asset_key: "contamination-board-colors", purpose: "Show the current cutting-board color assignments.", lesson_key: "practical-photo-guide", placement: "reference-card", alt_i18n: text("Six color-coded cutting boards arranged for their listed food groups.", "ستة ألواح تقطيع ملوّنة مرتبة لمجموعات الطعام المذكورة.", "Enam talenan berkode warna disusun untuk kelompok makanan yang tercantum.", "सूचीबद्ध भोजन समूहों के लिए व्यवस्थित छह रंग-कोडित कटिंग बोर्ड।", "Anim na color-coded cutting board para sa mga nakalistang food group."), approval_status: "needed" },
      { asset_key: "contamination-hazard-examples", purpose: "Show visible examples of biological-context, chemical, and physical hazards without adding facts.", lesson_key: "practical-photo-guide", placement: "hazard-cards", alt_i18n: text("Separate examples of raw poultry, cleaning chemical near food, and a staple as contamination hazards.", "أمثلة منفصلة لدواجن نيئة ومادة تنظيف قرب الطعام ودبوس بوصفها مخاطر تلوث.", "Contoh terpisah berupa unggas mentah, bahan pembersih dekat makanan, dan staples sebagai bahaya kontaminasi.", "संदूषण खतरों के रूप में कच्ची पोल्ट्री, भोजन के पास सफाई रसायन और स्टेपल के अलग उदाहरण।", "Magkakahiwalay na halimbawa ng raw poultry, cleaning chemical malapit sa pagkain, at staple bilang contamination hazards."), approval_status: "needed" },
    ],
    quiz_questions: [
      { stable_key: "raw-chicken-board", source_fact_keys: ["board-colors"], prompt_i18n: text("Which board color is listed for raw poultry?", "ما لون لوح التقطيع المذكور للدواجن النيئة؟", "Warna talenan apa yang tercantum untuk unggas mentah?", "कच्ची पोल्ट्री के लिए कौन-सा बोर्ड रंग सूचीबद्ध है?", "Anong board color ang nakalista para sa raw poultry?"), options: [option("a", text("Yellow", "الأصفر", "Kuning", "पीला", "Dilaw")), option("b", text("Green", "الأخضر", "Hijau", "हरा", "Berde")), option("c", text("White", "الأبيض", "Putih", "सफेद", "Puti"))], correct_option_key: "a", explanation_i18n: text("Yellow is the current curriculum color for raw poultry.", "الأصفر هو لون الدواجن النيئة في المنهج الحالي.", "Kuning adalah warna unggas mentah dalam kurikulum saat ini.", "वर्तमान पाठ्यक्रम में कच्ची पोल्ट्री का रंग पीला है।", "Dilaw ang kulay para sa raw poultry sa kasalukuyang kurikulum.") },
      { stable_key: "staple-hazard", source_fact_keys: ["physical-hazards"], prompt_i18n: text("A staple falling into food is which hazard type?", "إلى أي نوع من المخاطر ينتمي سقوط دبوس في الطعام؟", "Staples yang jatuh ke makanan termasuk jenis bahaya apa?", "भोजन में गिरा स्टेपल किस प्रकार का खतरा है?", "Anong hazard type ang staple na nahulog sa pagkain?"), options: [option("a", text("Biological", "بيولوجي", "Biologis", "जैविक", "Biological")), option("b", text("Chemical", "كيميائي", "Kimia", "रासायनिक", "Chemical")), option("c", text("Physical", "فيزيائي", "Fisik", "भौतिक", "Physical"))], correct_option_key: "c", explanation_i18n: text("The current curriculum lists staples as physical hazards.", "يذكر المنهج الحالي الدبابيس ضمن المخاطر الفيزيائية.", "Kurikulum saat ini mencantumkan staples sebagai bahaya fisik.", "वर्तमान पाठ्यक्रम स्टेपल को भौतिक खतरा बताता है।", "Nakalista sa kasalukuyang kurikulum ang staple bilang physical hazard.") },
      { stable_key: "danger-zone-range", source_fact_keys: ["temperature-danger-zone"], prompt_i18n: text("What Temperature Danger Zone is listed?", "ما نطاق منطقة خطر الحرارة المذكور؟", "Berapa rentang Temperature Danger Zone yang tercantum?", "कौन-सा तापमान खतरा क्षेत्र सूचीबद्ध है?", "Ano ang nakalistang Temperature Danger Zone?"), options: [option("a", text("0°C-4°C", "0°C-4°C", "0°C-4°C", "0°C-4°C", "0°C-4°C")), option("b", text("5°C-60°C", "5°C-60°C", "5°C-60°C", "5°C-60°C", "5°C-60°C")), option("c", text("63°C-74°C", "63°C-74°C", "63°C-74°C", "63°C-74°C", "63°C-74°C"))], correct_option_key: "b", explanation_i18n: text("The current curriculum lists 5°C-60°C.", "يذكر المنهج الحالي 5°C-60°C.", "Kurikulum saat ini mencantumkan 5°C-60°C.", "वर्तमान पाठ्यक्रम 5°C-60°C बताता है।", "Nakalista sa kasalukuyang kurikulum ang 5°C-60°C.") },
    ],
  },
  {
    stable_key: "safe-food-handling",
    position: 4,
    category_key: "food_safety",
    source_module_ids: ["safe-food-handling"],
    default_provenance_classification: supporting,
    title_i18n: text("Safe Food Handling", "التعامل الآمن مع الطعام", "Penanganan Makanan Aman", "सुरक्षित खाद्य हैंडलिंग", "Ligtas na Paghawak ng Pagkain"),
    description_i18n: text("Handwashing and glove limits, ready-to-eat food contact, and tasting-spoon controls from the current Training curriculum.", "حدود غسل اليدين والقفازات وملامسة الطعام الجاهز للأكل وضوابط ملعقة التذوق من منهج التدريب الحالي.", "Batas cuci tangan dan sarung tangan, kontak makanan siap santap, serta kontrol sendok cicip dari kurikulum Pelatihan saat ini.", "वर्तमान प्रशिक्षण पाठ्यक्रम से हाथ धोने और दस्ताने की सीमाएँ, खाने के लिए तैयार भोजन का संपर्क और चखने वाले चम्मच का नियंत्रण।", "Mga limitasyon sa handwashing at gloves, ready-to-eat food contact, at tasting-spoon controls mula sa kasalukuyang kurikulum."),
    lesson_objectives_i18n: {
      overview: text("Recognize the current controls for gloves, utensils, and ready-to-eat food.", "التعرّف على الضوابط الحالية للقفازات والأدوات والطعام الجاهز للأكل.", "Mengenali kontrol saat ini untuk sarung tangan, alat, dan makanan siap santap.", "दस्ताने, उपकरण और खाने के लिए तैयार भोजन के वर्तमान नियंत्रण पहचानें।", "Kilalanin ang kasalukuyang controls para sa gloves, utensils, at ready-to-eat food."),
      practical_photo_guide: text("Compare safe and unsafe food-handling examples.", "مقارنة أمثلة التعامل الآمن وغير الآمن مع الطعام.", "Membandingkan contoh penanganan makanan yang aman dan tidak aman.", "सुरक्षित और असुरक्षित खाद्य हैंडलिंग उदाहरणों की तुलना करें।", "Ihambing ang ligtas at hindi ligtas na food-handling examples."),
      knowledge_check: text("Check glove-change, utensil, and tasting-spoon decisions.", "التحقق من قرارات تغيير القفازات واستخدام الأدوات وملعقة التذوق.", "Memeriksa keputusan penggantian sarung tangan, alat, dan sendok cicip.", "दस्ताने बदलने, उपकरण और चखने वाले चम्मच के निर्णय जाँचें।", "Suriin ang glove-change, utensil, at tasting-spoon decisions."),
    },
    practical_mode: "reference",
    facts: [
      { fact_key: "no-bare-hand-rte", lesson_key: "overview", presentation: "key_point", position: 1, provenance_classification: supporting, text_i18n: text("The current curriculum calls for no bare-hand contact with ready-to-eat food.", "ينص المنهج الحالي على عدم ملامسة الطعام الجاهز للأكل باليد المجردة.", "Kurikulum saat ini melarang kontak tangan telanjang dengan makanan siap santap.", "वर्तमान पाठ्यक्रम खाने के लिए तैयार भोजन को नंगे हाथ से छूने से मना करता है।", "Hindi pinapayagan ng kasalukuyang kurikulum ang bare-hand contact sa ready-to-eat food.") },
      { fact_key: "gloves-not-handwash", lesson_key: "practical-photo-guide", presentation: "warning", position: 1, provenance_classification: supporting, text_i18n: text("Gloves do not replace handwashing.", "القفازات لا تغني عن غسل اليدين.", "Sarung tangan tidak menggantikan cuci tangan.", "दस्ताने हाथ धोने का स्थान नहीं लेते।", "Hindi kapalit ng paghuhugas ng kamay ang gloves.") },
      { fact_key: "glove-change", lesson_key: "practical-photo-guide", presentation: "key_point", position: 2, provenance_classification: supporting, text_i18n: text("Change gloves when torn, when changing tasks, after touching a dirty object, or after no more than 4 hours.", "غيّر القفازات عند تمزقها أو تغيير المهمة أو لمس شيء متسخ أو بعد مدة لا تتجاوز 4 ساعات.", "Ganti sarung tangan saat robek, berganti tugas, setelah menyentuh benda kotor, atau setelah paling lama 4 jam.", "दस्ताने फटने पर, कार्य बदलते समय, गंदी वस्तु छूने के बाद या अधिकतम 4 घंटे बाद बदलें।", "Palitan ang gloves kapag punit, nagpapalit ng gawain, pagkatapos humawak ng maruming bagay, o makalipas ang hindi hihigit sa 4 na oras.") },
      { fact_key: "rte-tools", lesson_key: "practical-photo-guide", presentation: "key_point", position: 3, provenance_classification: supporting, text_i18n: text("Use tongs, deli paper, or new gloves for ready-to-eat food.", "استخدم الملقط أو ورق الديلي أو قفازات جديدة للطعام الجاهز للأكل.", "Gunakan penjepit, kertas deli, atau sarung tangan baru untuk makanan siap santap.", "खाने के लिए तैयार भोजन के लिए चिमटा, डेली पेपर या नए दस्ताने उपयोग करें।", "Gumamit ng tongs, deli paper, o bagong gloves para sa ready-to-eat food.") },
      { fact_key: "tasting-spoon", lesson_key: "practical-photo-guide", presentation: "key_point", position: 4, provenance_classification: supporting, text_i18n: text("Use a tasting spoon once, or wash it after one taste.", "استخدم ملعقة التذوق مرة واحدة، أو اغسلها بعد تذوق واحد.", "Gunakan sendok cicip sekali, atau cuci setelah satu kali mencicip.", "चखने वाला चम्मच एक बार उपयोग करें या एक बार चखने के बाद धोएँ।", "Gamitin ang tasting spoon nang isang beses, o hugasan pagkatapos ng isang tikim.") },
      { fact_key: "raw-glove-cross-contact", lesson_key: "overview", presentation: "scenario", position: 2, provenance_classification: supporting, text_i18n: text("The current scenario shows a cook using the same gloves for raw chicken and burger bread.", "يعرض السيناريو الحالي طاهياً يستخدم القفازات نفسها للدجاج النيء وخبز البرغر.", "Skenario saat ini menunjukkan koki menggunakan sarung tangan yang sama untuk ayam mentah dan roti burger.", "वर्तमान परिदृश्य में रसोइया कच्चे चिकन और बर्गर ब्रेड के लिए वही दस्ताने उपयोग करता है।", "Ipinapakita ng kasalukuyang senaryo ang cook na gumagamit ng parehong gloves sa raw chicken at burger bread.") },
    ],
    photo_requirements: [
      { asset_key: "handling-gloves-handwashing", purpose: "Show that clean hands are required before gloves.", lesson_key: "overview", placement: "overview-hero", alt_i18n: text("Clean hands beside a fresh pair of disposable food gloves.", "يدان نظيفتان بجانب زوج جديد من قفازات الطعام أحادية الاستخدام.", "Tangan bersih di samping sepasang sarung tangan makanan sekali pakai yang baru.", "नए डिस्पोज़ेबल खाद्य दस्तानों के पास साफ हाथ।", "Malinis na kamay sa tabi ng bagong disposable food gloves."), approval_status: "needed" },
      { asset_key: "handling-rte-tools", purpose: "Show source-supported tools for ready-to-eat food.", lesson_key: "practical-photo-guide", placement: "reference-card", alt_i18n: text("Tongs, deli paper, and new gloves beside ready-to-eat food.", "ملقط وورق ديلي وقفازات جديدة بجانب طعام جاهز للأكل.", "Penjepit, kertas deli, dan sarung tangan baru di samping makanan siap santap.", "खाने के लिए तैयार भोजन के पास चिमटा, डेली पेपर और नए दस्ताने।", "Tongs, deli paper, at bagong gloves sa tabi ng ready-to-eat food."), approval_status: "needed" },
      { asset_key: "handling-cross-contact-comparison", purpose: "Contrast raw-chicken gloves with safe bread handling.", lesson_key: "practical-photo-guide", placement: "comparison-card", alt_i18n: text("Unsafe raw-chicken gloves kept separate from safely handled burger bread.", "قفازات دجاج نيء غير آمنة منفصلة عن خبز برغر يتم التعامل معه بأمان.", "Sarung tangan bekas ayam mentah yang tidak aman dipisahkan dari roti burger yang ditangani dengan aman.", "असुरक्षित कच्चे चिकन वाले दस्ताने सुरक्षित तरीके से सँभाली बर्गर ब्रेड से अलग।", "Hindi ligtas na raw-chicken gloves na hiwalay sa ligtas na paghawak ng burger bread."), approval_status: "needed" },
      { asset_key: "handling-tasting-spoon", purpose: "Show a single-use or freshly washed tasting spoon.", lesson_key: "practical-photo-guide", placement: "key-point-card", alt_i18n: text("Clean tasting spoon set aside after one taste.", "ملعقة تذوق نظيفة موضوعة جانباً بعد تذوق واحد.", "Sendok cicip bersih disisihkan setelah satu kali mencicip.", "एक बार चखने के बाद अलग रखा साफ चखने वाला चम्मच।", "Malinis na tasting spoon na isinantabi pagkatapos ng isang tikim."), approval_status: "needed" },
    ],
    quiz_questions: [
      { stable_key: "gloves-replace-handwashing", source_fact_keys: ["gloves-not-handwash"], prompt_i18n: text("Do food gloves replace handwashing?", "هل تغني قفازات الطعام عن غسل اليدين؟", "Apakah sarung tangan makanan menggantikan cuci tangan?", "क्या खाद्य दस्ताने हाथ धोने का स्थान लेते हैं?", "Kapalit ba ng paghuhugas ng kamay ang food gloves?"), options: [option("a", text("Yes, for short tasks", "نعم، للمهام القصيرة", "Ya, untuk tugas singkat", "हाँ, छोटे कार्यों के लिए", "Oo, para sa maikling gawain")), option("b", text("No", "لا", "Tidak", "नहीं", "Hindi")), option("c", text("Only during busy service", "فقط أثناء ضغط الخدمة", "Hanya saat layanan sibuk", "केवल व्यस्त सेवा के दौरान", "Sa busy service lamang"))], correct_option_key: "b", explanation_i18n: text("The current curriculum states that gloves do not replace handwashing.", "ينص المنهج الحالي على أن القفازات لا تغني عن غسل اليدين.", "Kurikulum saat ini menyatakan bahwa sarung tangan tidak menggantikan cuci tangan.", "वर्तमान पाठ्यक्रम कहता है कि दस्ताने हाथ धोने का स्थान नहीं लेते।", "Sinasabi ng kasalukuyang kurikulum na hindi kapalit ng paghuhugas ng kamay ang gloves.") },
      { stable_key: "rte-contact-tool", source_fact_keys: ["rte-tools"], prompt_i18n: text("Which is an approved current-curriculum method for handling ready-to-eat food?", "أي طريقة يقرها المنهج الحالي للتعامل مع الطعام الجاهز للأكل؟", "Metode mana yang disetujui kurikulum saat ini untuk menangani makanan siap santap?", "खाने के लिए तैयार भोजन सँभालने की वर्तमान पाठ्यक्रम द्वारा स्वीकृत विधि कौन-सी है?", "Alin ang aprubadong paraan sa kasalukuyang kurikulum para humawak ng ready-to-eat food?"), options: [option("a", text("Bare hands", "اليدان المجردتان", "Tangan telanjang", "नंगे हाथ", "Bare hands")), option("b", text("Used raw-food gloves", "قفازات مستخدمة للطعام النيء", "Sarung tangan bekas bahan mentah", "उपयोग किए कच्चे-भोजन दस्ताने", "Ginamit na raw-food gloves")), option("c", text("Tongs, deli paper, or new gloves", "ملقط أو ورق ديلي أو قفازات جديدة", "Penjepit, kertas deli, atau sarung tangan baru", "चिमटा, डेली पेपर या नए दस्ताने", "Tongs, deli paper, o bagong gloves"))], correct_option_key: "c", explanation_i18n: text("The current curriculum lists tongs, deli paper, or new gloves.", "يذكر المنهج الحالي الملقط أو ورق الديلي أو القفازات الجديدة.", "Kurikulum saat ini mencantumkan penjepit, kertas deli, atau sarung tangan baru.", "वर्तमान पाठ्यक्रम चिमटा, डेली पेपर या नए दस्ताने बताता है।", "Nakalista sa kasalukuyang kurikulum ang tongs, deli paper, o bagong gloves.") },
      { stable_key: "tasting-spoon-use", source_fact_keys: ["tasting-spoon"], prompt_i18n: text("What should happen after one use of a tasting spoon?", "ماذا يجب أن يحدث بعد استخدام ملعقة التذوق مرة واحدة؟", "Apa yang harus dilakukan setelah sendok cicip digunakan sekali?", "चखने वाले चम्मच के एक उपयोग के बाद क्या होना चाहिए?", "Ano ang dapat gawin pagkatapos ng isang gamit ng tasting spoon?"), options: [option("a", text("Reuse it immediately", "إعادة استخدامها فوراً", "Gunakan kembali segera", "तुरंत फिर उपयोग करें", "Gamitin agad muli")), option("b", text("Set it on the prep table", "وضعها على طاولة التحضير", "Letakkan di meja persiapan", "तैयारी मेज़ पर रखें", "Ilagay sa prep table")), option("c", text("Discard it if single-use, or wash it", "تخلّص منها إن كانت أحادية الاستخدام أو اغسلها", "Buang jika sekali pakai, atau cuci", "एक बार उपयोग वाली हो तो फेंकें, अन्यथा धोएँ", "Itapon kung single-use, o hugasan"))], correct_option_key: "c", explanation_i18n: text("The current curriculum allows one use or washing after one taste.", "يسمح المنهج الحالي باستخدام واحد أو الغسل بعد تذوق واحد.", "Kurikulum saat ini memperbolehkan satu kali penggunaan atau pencucian setelah satu kali mencicip.", "वर्तमान पाठ्यक्रम एक बार उपयोग या एक बार चखने के बाद धोने की अनुमति देता है।", "Pinapayagan ng kasalukuyang kurikulum ang isang gamit o paghuhugas pagkatapos ng isang tikim.") },
    ],
  },
  {
    stable_key: "food-receiving",
    position: 5,
    category_key: "operations",
    source_module_ids: ["receiving-food"],
    default_provenance_classification: supporting,
    title_i18n: text("Food Receiving", "استلام الأغذية", "Penerimaan Makanan", "खाद्य प्राप्ति", "Pagtanggap ng Pagkain"),
    description_i18n: text("Delivery temperatures, package integrity, and timely cold-storage transfer from the current Training curriculum.", "درجات حرارة الاستلام وسلامة العبوات والنقل السريع إلى التخزين البارد من منهج التدريب الحالي.", "Suhu penerimaan, integritas kemasan, dan pemindahan tepat waktu ke penyimpanan dingin dari kurikulum Pelatihan saat ini.", "वर्तमान प्रशिक्षण पाठ्यक्रम से डिलीवरी तापमान, पैकेज की अखंडता और समय पर ठंडे भंडारण में स्थानांतरण।", "Delivery temperatures, package integrity, at napapanahong paglipat sa cold storage mula sa kasalukuyang kurikulum."),
    lesson_objectives_i18n: {
      overview: text("Recognize the current receiving limits and rejection signs.", "التعرّف على حدود الاستلام وعلامات الرفض الحالية.", "Mengenali batas penerimaan dan tanda penolakan saat ini.", "वर्तमान प्राप्ति सीमाएँ और अस्वीकृति संकेत पहचानें।", "Kilalanin ang kasalukuyang receiving limits at rejection signs."),
      practical_photo_guide: text("Follow the supported temperature, package, and storage-transfer inspection flow.", "اتباع مسار فحص الحرارة والعبوة والنقل إلى التخزين المدعوم بالمصدر.", "Mengikuti alur pemeriksaan suhu, kemasan, dan pemindahan penyimpanan yang didukung sumber.", "स्रोत-समर्थित तापमान, पैकेज और भंडारण-स्थानांतरण निरीक्षण क्रम अपनाएँ।", "Sundin ang source-supported temperature, package, at storage-transfer inspection flow."),
      knowledge_check: text("Check receiving temperatures, packaging decisions, and transfer timing.", "التحقق من درجات حرارة الاستلام وقرارات العبوة وتوقيت النقل.", "Memeriksa suhu penerimaan, keputusan kemasan, dan waktu pemindahan.", "प्राप्ति तापमान, पैकेज निर्णय और स्थानांतरण समय जाँचें।", "Suriin ang receiving temperatures, packaging decisions, at transfer timing."),
    },
    practical_mode: "procedure",
    facts: [
      { fact_key: "receiving-scope", lesson_key: "overview", presentation: "overview", position: 1, provenance_classification: supporting, text_i18n: text("The current curriculum covers vehicle temperature, expiry date, labels, and package integrity during receiving.", "يغطي المنهج الحالي حرارة المركبة وتاريخ الانتهاء والملصقات وسلامة العبوة أثناء الاستلام.", "Kurikulum saat ini mencakup suhu kendaraan, tanggal kedaluwarsa, label, dan integritas kemasan saat penerimaan.", "वर्तमान पाठ्यक्रम प्राप्ति के दौरान वाहन तापमान, समाप्ति तिथि, लेबल और पैकेज अखंडता को शामिल करता है।", "Saklaw ng kasalukuyang kurikulum ang vehicle temperature, expiry date, labels, at package integrity sa receiving.") },
      { fact_key: "receiving-frozen", lesson_key: "practical-photo-guide", presentation: "step", position: 1, provenance_classification: supporting, text_i18n: text("Receive frozen food at no more than -18°C.", "استلم الطعام المجمد بدرجة لا تزيد على -18°C.", "Terima makanan beku pada suhu tidak lebih dari -18°C.", "जमे भोजन को -18°C से अधिक तापमान पर स्वीकार न करें।", "Tanggapin ang frozen food sa hindi hihigit sa -18°C.") },
      { fact_key: "receiving-chilled", lesson_key: "practical-photo-guide", presentation: "step", position: 2, provenance_classification: supporting, text_i18n: text("Receive chilled meat, dairy, and poultry at no more than 4°C; receive fresh eggs at no more than 7°C with intact shells.", "استلم اللحوم المبردة والألبان والدواجن بدرجة لا تزيد على 4°C، والبيض الطازج بدرجة لا تزيد على 7°C مع قشرة سليمة.", "Terima daging, susu, dan unggas dingin pada suhu tidak lebih dari 4°C; terima telur segar pada suhu tidak lebih dari 7°C dengan cangkang utuh.", "ठंडा मांस, डेयरी और पोल्ट्री 4°C से अधिक पर न लें; ताज़े अंडे 7°C से अधिक पर न लें और खोल साबुत हों।", "Tanggapin ang chilled meat, dairy, at poultry sa hindi hihigit sa 4°C; tanggapin ang sariwang itlog sa hindi hihigit sa 7°C at buo ang shell.") },
      { fact_key: "receiving-damaged-cans", lesson_key: "practical-photo-guide", presentation: "step", position: 3, provenance_classification: supporting, text_i18n: text("Reject cans that are swollen, leaking, severely rusted, or dented at the seam.", "ارفض العلب المنتفخة أو المتسربة أو شديدة الصدأ أو المنبعجة عند الحافة.", "Tolak kaleng yang menggembung, bocor, sangat berkarat, atau penyok pada sambungan.", "फूले, रिसते, बहुत जंग लगे या सीम पर दबे डिब्बे अस्वीकार करें।", "Tanggihan ang lata na umbok, tumutulo, sobrang kalawangin, o yupi sa seam.") },
      { fact_key: "receiving-transfer-time", lesson_key: "practical-photo-guide", presentation: "step", position: 4, provenance_classification: supporting, text_i18n: text("Move accepted perishable food to the chiller or freezer within 15 minutes.", "انقل الطعام سريع التلف المقبول إلى المبرد أو المجمد خلال 15 دقيقة.", "Pindahkan makanan mudah rusak yang diterima ke chiller atau freezer dalam 15 menit.", "स्वीकृत शीघ्र खराब होने वाले भोजन को 15 मिनट के भीतर चिलर या फ्रीज़र में रखें।", "Ilipat ang tinanggap na perishable food sa chiller o freezer sa loob ng 15 minuto.") },
    ],
    photo_requirements: [
      { asset_key: "receiving-temperature-check", purpose: "Show a receiving temperature check for frozen and chilled food.", lesson_key: "practical-photo-guide", placement: "procedure-steps", alt_i18n: text("Employee checking the receiving temperature of a packaged cold food item.", "موظف يفحص درجة حرارة استلام مادة غذائية باردة ومعبأة.", "Karyawan memeriksa suhu penerimaan bahan makanan dingin dalam kemasan.", "कर्मचारी पैक ठंडे खाद्य पदार्थ का प्राप्ति तापमान जाँचता हुआ।", "Empleyado na sumusuri sa receiving temperature ng naka-package na cold food item."), approval_status: "needed" },
      { asset_key: "receiving-intact-eggs", purpose: "Show intact fresh-egg shells at receiving.", lesson_key: "practical-photo-guide", placement: "reference-card", alt_i18n: text("Fresh eggs with intact shells during receiving inspection.", "بيض طازج بقشرة سليمة أثناء فحص الاستلام.", "Telur segar dengan cangkang utuh saat pemeriksaan penerimaan.", "प्राप्ति निरीक्षण में साबुत खोल वाले ताज़े अंडे।", "Sariwang itlog na buo ang shell sa receiving inspection."), approval_status: "needed" },
      { asset_key: "receiving-can-comparison", purpose: "Compare an acceptable can with the listed rejection signs.", lesson_key: "practical-photo-guide", placement: "comparison-card", alt_i18n: text("Acceptable can beside swollen, leaking, rusted, and seam-dented examples.", "علبة سليمة بجانب أمثلة منتفخة ومتسربة وصدئة ومنبعجة عند الحافة.", "Kaleng yang dapat diterima di samping contoh menggembung, bocor, berkarat, dan penyok pada sambungan.", "स्वीकार्य डिब्बे के पास फूले, रिसते, जंग लगे और सीम पर दबे उदाहरण।", "Katanggap-tanggap na lata katabi ng umbok, tumutulo, kalawangin, at seam-dented na mga halimbawa."), approval_status: "needed" },
      { asset_key: "receiving-cold-storage-transfer", purpose: "Show accepted perishables being moved to cold storage.", lesson_key: "practical-photo-guide", placement: "procedure-step-final", alt_i18n: text("Accepted perishable food being moved promptly into a chiller.", "طعام سريع التلف مقبول يُنقل سريعاً إلى المبرد.", "Makanan mudah rusak yang diterima segera dipindahkan ke chiller.", "स्वीकृत शीघ्र खराब होने वाला भोजन तुरंत चिलर में रखा जा रहा है।", "Tinanggap na perishable food na agad inililipat sa chiller."), approval_status: "needed" },
    ],
    quiz_questions: [
      { stable_key: "frozen-receiving-temperature", source_fact_keys: ["receiving-frozen"], prompt_i18n: text("What is the listed maximum receiving temperature for frozen food?", "ما أقصى درجة حرارة استلام مذكورة للطعام المجمد؟", "Berapa suhu penerimaan maksimum yang tercantum untuk makanan beku?", "जमे भोजन के लिए सूचीबद्ध अधिकतम प्राप्ति तापमान क्या है?", "Ano ang nakalistang maximum receiving temperature para sa frozen food?"), options: [option("a", text("-18°C", "-18°C", "-18°C", "-18°C", "-18°C")), option("b", text("4°C", "4°C", "4°C", "4°C", "4°C")), option("c", text("7°C", "7°C", "7°C", "7°C", "7°C"))], correct_option_key: "a", explanation_i18n: text("The current curriculum lists frozen food at no more than -18°C.", "يذكر المنهج الحالي الطعام المجمد بدرجة لا تزيد على -18°C.", "Kurikulum saat ini mencantumkan makanan beku pada suhu tidak lebih dari -18°C.", "वर्तमान पाठ्यक्रम जमे भोजन के लिए -18°C से अधिक नहीं बताता है।", "Nakalista sa kasalukuyang kurikulum ang frozen food sa hindi hihigit sa -18°C.") },
      { stable_key: "damaged-can-decision", source_fact_keys: ["receiving-damaged-cans"], prompt_i18n: text("What should happen to a swollen can?", "ماذا يجب أن يحدث للعلبة المنتفخة؟", "Apa yang harus dilakukan pada kaleng menggembung?", "फूले हुए डिब्बे के साथ क्या करना चाहिए?", "Ano ang dapat gawin sa umbok na lata?"), options: [option("a", text("Accept and label it", "قبولها ووضع ملصق عليها", "Terima dan beri label", "स्वीकार कर लेबल लगाएँ", "Tanggapin at lagyan ng label")), option("b", text("Reject it", "رفضها", "Tolak", "अस्वीकार करें", "Tanggihan")), option("c", text("Open and inspect it", "فتحها وفحصها", "Buka dan periksa", "खोलकर जाँचें", "Buksan at suriin"))], correct_option_key: "b", explanation_i18n: text("The current curriculum requires swollen cans to be rejected.", "يشترط المنهج الحالي رفض العلب المنتفخة.", "Kurikulum saat ini mengharuskan kaleng menggembung ditolak.", "वर्तमान पाठ्यक्रम फूले डिब्बों को अस्वीकार करने को कहता है।", "Kailangan sa kasalukuyang kurikulum na tanggihan ang umbok na lata.") },
      { stable_key: "perishable-transfer-time", source_fact_keys: ["receiving-transfer-time"], prompt_i18n: text("Within how long should accepted perishables reach cold storage?", "خلال كم من الوقت يجب أن تصل الأغذية سريعة التلف المقبولة إلى التخزين البارد؟", "Dalam berapa lama makanan mudah rusak yang diterima harus masuk penyimpanan dingin?", "स्वीकृत शीघ्र खराब होने वाला भोजन कितने समय में ठंडे भंडारण तक पहुँचना चाहिए?", "Sa loob ng gaano katagal dapat mailipat sa cold storage ang tinanggap na perishables?"), options: [option("a", text("15 minutes", "15 دقيقة", "15 menit", "15 मिनट", "15 minuto")), option("b", text("30 minutes", "30 دقيقة", "30 menit", "30 मिनट", "30 minuto")), option("c", text("60 minutes", "60 دقيقة", "60 menit", "60 मिनट", "60 minuto"))], correct_option_key: "a", explanation_i18n: text("The current curriculum sets a 15-minute transfer limit.", "يحدد المنهج الحالي حد النقل بـ 15 دقيقة.", "Kurikulum saat ini menetapkan batas pemindahan 15 menit.", "वर्तमान पाठ्यक्रम 15 मिनट की स्थानांतरण सीमा तय करता है।", "Nagtatakda ang kasalukuyang kurikulum ng 15-minutong transfer limit.") },
    ],
  },
  {
    stable_key: "storage-temperature-control",
    position: 6,
    category_key: "operations",
    source_module_ids: ["storage-temperature"],
    default_provenance_classification: supporting,
    title_i18n: text("Storage & Temperature Control", "التخزين وضبط الحرارة", "Penyimpanan & Kontrol Suhu", "भंडारण और तापमान नियंत्रण", "Storage at Temperature Control"),
    description_i18n: text("Temperature logs, chiller hierarchy, dry-storage conditions, and shelf clearances from the current Training curriculum.", "سجلات الحرارة وترتيب المبرد وظروف التخزين الجاف ومسافات الرفوف من منهج التدريب الحالي.", "Log suhu, susunan chiller, kondisi penyimpanan kering, dan jarak rak dari kurikulum Pelatihan saat ini.", "वर्तमान प्रशिक्षण पाठ्यक्रम से तापमान लॉग, चिलर क्रम, सूखे भंडारण की स्थितियाँ और रैक की दूरियाँ।", "Temperature logs, chiller hierarchy, dry-storage conditions, at shelf clearances mula sa kasalukuyang kurikulum."),
    lesson_objectives_i18n: {
      overview: text("Recognize the current storage temperatures, logging frequency, and shelf hierarchy.", "التعرّف على درجات حرارة التخزين وتكرار التسجيل وترتيب الرفوف الحالي.", "Mengenali suhu penyimpanan, frekuensi pencatatan, dan susunan rak saat ini.", "वर्तमान भंडारण तापमान, लॉग आवृत्ति और रैक क्रम पहचानें।", "Kilalanin ang kasalukuyang storage temperatures, logging frequency, at shelf hierarchy."),
      practical_photo_guide: text("Use photo references for safe chiller layout and storage clearances.", "استخدام مراجع مصورة لترتيب المبرد الآمن ومسافات التخزين.", "Menggunakan referensi foto untuk susunan chiller aman dan jarak penyimpanan.", "सुरक्षित चिलर व्यवस्था और भंडारण दूरी के लिए फोटो संदर्भ उपयोग करें।", "Gumamit ng photo references para sa ligtas na chiller layout at storage clearances."),
      knowledge_check: text("Check logging, shelf placement, and dry-storage limits.", "التحقق من التسجيل ووضع الرفوف وحدود التخزين الجاف.", "Memeriksa pencatatan, penempatan rak, dan batas penyimpanan kering.", "लॉगिंग, रैक स्थान और सूखे भंडारण सीमाएँ जाँचें।", "Suriin ang logging, shelf placement, at dry-storage limits."),
    },
    practical_mode: "reference",
    facts: [
      { fact_key: "temperature-log-frequency", lesson_key: "overview", presentation: "key_point", position: 1, provenance_classification: supporting, text_i18n: text("Record chiller, freezer, and dry-storage temperatures at least twice each day.", "سجّل درجات حرارة المبرد والمجمد والتخزين الجاف مرتين يومياً على الأقل.", "Catat suhu chiller, freezer, dan penyimpanan kering setidaknya dua kali setiap hari.", "चिलर, फ्रीज़र और सूखे भंडारण का तापमान हर दिन कम से कम दो बार दर्ज करें।", "Itala ang chiller, freezer, at dry-storage temperatures nang hindi bababa sa dalawang beses bawat araw.") },
      { fact_key: "upper-shelf-rte", lesson_key: "practical-photo-guide", presentation: "key_point", position: 1, provenance_classification: supporting, text_i18n: text("Use upper shelves for cooked food, ready-to-eat food, cake, and ready-to-serve produce.", "استخدم الرفوف العليا للطعام المطهو والجاهز للأكل والكيك والخضار الجاهزة للتقديم.", "Gunakan rak atas untuk makanan matang, makanan siap santap, kue, dan hasil bumi siap saji.", "ऊपरी रैक पके भोजन, खाने के लिए तैयार भोजन, केक और परोसने के लिए तैयार फल-सब्ज़ी के लिए उपयोग करें।", "Gamitin ang upper shelves para sa cooked food, ready-to-eat food, cake, at ready-to-serve produce.") },
      { fact_key: "bottom-shelf-poultry", lesson_key: "practical-photo-guide", presentation: "key_point", position: 2, provenance_classification: supporting, text_i18n: text("Store raw poultry on the bottom shelf because it has the highest listed internal cooking temperature.", "خزّن الدواجن النيئة على الرف السفلي لأن لها أعلى درجة طهي داخلية مذكورة.", "Simpan unggas mentah di rak paling bawah karena memiliki suhu masak internal tertinggi yang tercantum.", "कच्ची पोल्ट्री नीचे वाले रैक पर रखें क्योंकि उसका सूचीबद्ध आंतरिक पकाने का तापमान सबसे अधिक है।", "Ilagay ang raw poultry sa bottom shelf dahil ito ang may pinakamataas na nakalistang internal cooking temperature.") },
      { fact_key: "dry-storage-range", lesson_key: "overview", presentation: "key_point", position: 2, provenance_classification: supporting, text_i18n: text("Keep dry storage at 15°C-25°C and 50%-60% humidity.", "حافظ على التخزين الجاف بدرجة 15°C-25°C ورطوبة 50%-60%.", "Jaga penyimpanan kering pada 15°C-25°C dan kelembapan 50%-60%.", "सूखे भंडारण को 15°C-25°C और 50%-60% आर्द्रता पर रखें।", "Panatilihin ang dry storage sa 15°C-25°C at 50%-60% humidity.") },
      { fact_key: "shelf-clearance", lesson_key: "practical-photo-guide", presentation: "key_point", position: 3, provenance_classification: supporting, text_i18n: text("Keep shelving at least 15 cm above the floor and 10 cm away from the wall.", "اجعل الرفوف على ارتفاع لا يقل عن 15 cm عن الأرض وعلى مسافة 10 cm عن الجدار.", "Jaga rak setidaknya 15 cm dari lantai dan 10 cm dari dinding.", "रैक फर्श से कम से कम 15 cm ऊपर और दीवार से 10 cm दूर रखें।", "Panatilihin ang shelving nang hindi bababa sa 15 cm mula sa sahig at 10 cm mula sa dingding.") },
    ],
    photo_requirements: [
      { asset_key: "storage-chiller-hierarchy", purpose: "Show the listed upper- and bottom-shelf arrangement.", lesson_key: "practical-photo-guide", placement: "reference-card", alt_i18n: text("Chiller with cooked and ready-to-eat food above and raw poultry on the bottom shelf.", "مبرد فيه الطعام المطهو والجاهز للأكل في الأعلى والدواجن النيئة على الرف السفلي.", "Chiller dengan makanan matang dan siap santap di atas serta unggas mentah di rak paling bawah.", "चिलर में ऊपर पका और खाने के लिए तैयार भोजन तथा नीचे कच्ची पोल्ट्री।", "Chiller na may cooked at ready-to-eat food sa itaas at raw poultry sa bottom shelf."), approval_status: "needed" },
      { asset_key: "storage-temperature-log", purpose: "Show a chiller thermometer and temperature record.", lesson_key: "overview", placement: "overview-hero", alt_i18n: text("Chiller thermometer beside a temperature log record.", "مقياس حرارة مبرد بجانب سجل درجات الحرارة.", "Termometer chiller di samping catatan log suhu.", "तापमान लॉग के पास चिलर थर्मामीटर।", "Chiller thermometer sa tabi ng temperature log record."), approval_status: "needed" },
      { asset_key: "storage-shelf-clearance", purpose: "Show the listed floor and wall clearances.", lesson_key: "practical-photo-guide", placement: "measurement-reference", alt_i18n: text("Storage rack positioned 15 cm above the floor and 10 cm from the wall.", "رف تخزين على ارتفاع 15 cm عن الأرض وعلى مسافة 10 cm من الجدار.", "Rak penyimpanan berada 15 cm di atas lantai dan 10 cm dari dinding.", "भंडारण रैक फर्श से 15 cm ऊपर और दीवार से 10 cm दूर।", "Storage rack na 15 cm mula sa sahig at 10 cm mula sa dingding."), approval_status: "needed" },
      { asset_key: "storage-dry-conditions", purpose: "Show dry-storage temperature and humidity readings.", lesson_key: "practical-photo-guide", placement: "reference-card", alt_i18n: text("Dry-storage display showing temperature and humidity readings.", "شاشة تخزين جاف تعرض قراءات الحرارة والرطوبة.", "Layar penyimpanan kering menampilkan suhu dan kelembapan.", "तापमान और आर्द्रता दिखाता सूखा-भंडारण डिस्प्ले।", "Dry-storage display na nagpapakita ng temperature at humidity readings."), approval_status: "needed" },
    ],
    quiz_questions: [
      { stable_key: "temperature-log-frequency", source_fact_keys: ["temperature-log-frequency"], prompt_i18n: text("How often are storage temperatures listed for recording?", "كم مرة يجب تسجيل درجات حرارة التخزين؟", "Seberapa sering suhu penyimpanan harus dicatat?", "भंडारण तापमान कितनी बार दर्ज करना है?", "Gaano kadalas dapat itala ang storage temperatures?"), options: [option("a", text("At least twice daily", "مرتين يومياً على الأقل", "Setidaknya dua kali sehari", "दिन में कम से कम दो बार", "Hindi bababa sa dalawang beses araw-araw")), option("b", text("Once weekly", "مرة أسبوعياً", "Sekali seminggu", "सप्ताह में एक बार", "Isang beses kada linggo")), option("c", text("Only after a fault", "فقط بعد حدوث عطل", "Hanya setelah kerusakan", "केवल खराबी के बाद", "Pagkatapos lamang ng fault"))], correct_option_key: "a", explanation_i18n: text("The current curriculum says at least twice each day.", "يذكر المنهج الحالي مرتين يومياً على الأقل.", "Kurikulum saat ini menyatakan setidaknya dua kali setiap hari.", "वर्तमान पाठ्यक्रम दिन में कम से कम दो बार कहता है।", "Sinasabi ng kasalukuyang kurikulum na hindi bababa sa dalawang beses bawat araw.") },
      { stable_key: "bottom-chiller-shelf", source_fact_keys: ["bottom-shelf-poultry"], prompt_i18n: text("What belongs on the bottom chiller shelf?", "ما الذي يوضع على الرف السفلي للمبرد؟", "Apa yang ditempatkan di rak paling bawah chiller?", "चिलर के सबसे नीचे वाले रैक पर क्या रखना चाहिए?", "Ano ang dapat ilagay sa bottom chiller shelf?"), options: [option("a", text("Cake", "الكيك", "Kue", "केक", "Cake")), option("b", text("Ready-to-eat produce", "الخضار الجاهزة للأكل", "Hasil bumi siap santap", "खाने के लिए तैयार फल-सब्ज़ी", "Ready-to-eat produce")), option("c", text("Raw poultry", "الدواجن النيئة", "Unggas mentah", "कच्ची पोल्ट्री", "Raw poultry"))], correct_option_key: "c", explanation_i18n: text("The current curriculum assigns raw poultry to the bottom shelf.", "يخصص المنهج الحالي الرف السفلي للدواجن النيئة.", "Kurikulum saat ini menempatkan unggas mentah di rak paling bawah.", "वर्तमान पाठ्यक्रम कच्ची पोल्ट्री को नीचे वाले रैक पर रखता है।", "Itinalaga ng kasalukuyang kurikulum ang raw poultry sa bottom shelf.") },
      { stable_key: "dry-storage-range", source_fact_keys: ["dry-storage-range"], prompt_i18n: text("Which dry-storage range is listed?", "أي نطاق للتخزين الجاف مذكور؟", "Rentang penyimpanan kering mana yang tercantum?", "कौन-सी सूखा-भंडारण सीमा सूचीबद्ध है?", "Aling dry-storage range ang nakalista?"), options: [option("a", text("15°C-25°C and 50%-60% humidity", "15°C-25°C ورطوبة 50%-60%", "15°C-25°C dan kelembapan 50%-60%", "15°C-25°C और 50%-60% आर्द्रता", "15°C-25°C at 50%-60% humidity")), option("b", text("0°C-4°C and 80%-90% humidity", "0°C-4°C ورطوبة 80%-90%", "0°C-4°C dan kelembapan 80%-90%", "0°C-4°C और 80%-90% आर्द्रता", "0°C-4°C at 80%-90% humidity")), option("c", text("30°C-40°C and 10%-20% humidity", "30°C-40°C ورطوبة 10%-20%", "30°C-40°C dan kelembapan 10%-20%", "30°C-40°C और 10%-20% आर्द्रता", "30°C-40°C at 10%-20% humidity"))], correct_option_key: "a", explanation_i18n: text("The current curriculum lists 15°C-25°C and 50%-60% humidity.", "يذكر المنهج الحالي 15°C-25°C ورطوبة 50%-60%.", "Kurikulum saat ini mencantumkan 15°C-25°C dan kelembapan 50%-60%.", "वर्तमान पाठ्यक्रम 15°C-25°C और 50%-60% आर्द्रता बताता है।", "Nakalista sa kasalukuyang kurikulum ang 15°C-25°C at 50%-60% humidity.") },
    ],
  },
  {
    stable_key: "cooking-holding-reheating",
    position: 7,
    category_key: "operations",
    source_module_ids: ["cooking-reheating"],
    default_provenance_classification: supporting,
    title_i18n: text("Cooking, Holding & Reheating", "الطهي والحفظ وإعادة التسخين", "Memasak, Menahan & Memanaskan Ulang", "पकाना, होल्डिंग और दोबारा गर्म करना", "Pagluluto, Holding at Reheating"),
    description_i18n: text("Internal temperatures, holding limits, and reheating controls from the current Training curriculum.", "درجات الحرارة الداخلية وحدود الحفظ وضوابط إعادة التسخين من منهج التدريب الحالي.", "Suhu internal, batas holding, dan kontrol pemanasan ulang dari kurikulum Pelatihan saat ini.", "वर्तमान प्रशिक्षण पाठ्यक्रम से आंतरिक तापमान, होल्डिंग सीमाएँ और दोबारा गर्म करने के नियंत्रण।", "Internal temperatures, holding limits, at reheating controls mula sa kasalukuyang kurikulum."),
    lesson_objectives_i18n: {
      overview: text("Recognize the listed cooking, hot-holding, cold-holding, and reheating limits.", "التعرّف على حدود الطهي والحفظ الساخن والحفظ البارد وإعادة التسخين المذكورة.", "Mengenali batas memasak, hot holding, cold holding, dan pemanasan ulang yang tercantum.", "सूचीबद्ध पकाने, गर्म होल्डिंग, ठंडी होल्डिंग और दोबारा गर्म करने की सीमाएँ पहचानें।", "Kilalanin ang nakalistang cooking, hot-holding, cold-holding, at reheating limits."),
      practical_photo_guide: text("Use photo reference cards for temperature decisions; no unsupported thermometer procedure is added.", "استخدام بطاقات مرجعية مصورة لقرارات الحرارة من دون إضافة إجراء غير مدعوم لاستخدام مقياس الحرارة.", "Menggunakan kartu referensi foto untuk keputusan suhu tanpa menambahkan prosedur termometer yang tidak didukung.", "तापमान निर्णयों के लिए फोटो संदर्भ कार्ड उपयोग करें; कोई असमर्थित थर्मामीटर प्रक्रिया न जोड़ें।", "Gumamit ng photo reference cards para sa temperature decisions; walang idinadagdag na unsupported thermometer procedure."),
      knowledge_check: text("Check poultry, holding, and reheating limits.", "التحقق من حدود الدواجن والحفظ وإعادة التسخين.", "Memeriksa batas unggas, holding, dan pemanasan ulang.", "पोल्ट्री, होल्डिंग और दोबारा गर्म करने की सीमाएँ जाँचें।", "Suriin ang poultry, holding, at reheating limits."),
    },
    practical_mode: "reference",
    facts: [
      { fact_key: "poultry-temperature", lesson_key: "overview", presentation: "key_point", position: 1, provenance_classification: supporting, text_i18n: text("Cook poultry, and reheat food, to 74°C for at least 15 seconds.", "اطهِ الدواجن وأعد تسخين الطعام إلى 74°C لمدة لا تقل عن 15 ثانية.", "Masak unggas, dan panaskan ulang makanan, hingga 74°C selama setidaknya 15 detik.", "पोल्ट्री पकाएँ और भोजन को 74°C पर कम से कम 15 सेकंड तक दोबारा गर्म करें।", "Lutuin ang poultry, at i-reheat ang pagkain, sa 74°C nang hindi bababa sa 15 segundo.") },
      { fact_key: "ground-meat-temperature", lesson_key: "overview", presentation: "key_point", position: 2, provenance_classification: supporting, text_i18n: text("Cook ground meat to 68°C for at least 15 seconds.", "اطهِ اللحم المفروم إلى 68°C لمدة لا تقل عن 15 ثانية.", "Masak daging giling hingga 68°C selama setidaknya 15 detik.", "ग्राउंड मीट को 68°C पर कम से कम 15 सेकंड पकाएँ।", "Lutuin ang ground meat sa 68°C nang hindi bababa sa 15 segundo.") },
      { fact_key: "seafood-steak-egg-temperature", lesson_key: "overview", presentation: "key_point", position: 3, provenance_classification: supporting, text_i18n: text("Cook seafood, steak, and eggs for immediate service to 63°C for at least 15 seconds.", "اطهِ المأكولات البحرية والستيك والبيض المعد للتقديم الفوري إلى 63°C لمدة لا تقل عن 15 ثانية.", "Masak seafood, steak, dan telur untuk penyajian langsung hingga 63°C selama setidaknya 15 detik.", "तुरंत परोसने वाले समुद्री भोजन, स्टेक और अंडों को 63°C पर कम से कम 15 सेकंड पकाएँ।", "Lutuin ang seafood, steak, at itlog para sa agarang serbisyo sa 63°C nang hindi bababa sa 15 segundo.") },
      { fact_key: "holding-limits", lesson_key: "practical-photo-guide", presentation: "key_point", position: 1, provenance_classification: supporting, text_i18n: text("Keep hot-held food at no less than 60°C and cold-held food at no more than 4°C.", "احفظ الطعام الساخن عند 60°C على الأقل والطعام البارد عند 4°C كحد أقصى.", "Jaga makanan hot holding minimal 60°C dan cold holding maksimal 4°C.", "गर्म होल्ड भोजन कम से कम 60°C और ठंडा होल्ड भोजन अधिकतम 4°C पर रखें।", "Panatilihin ang hot-held food sa hindi bababa sa 60°C at cold-held food sa hindi hihigit sa 4°C.") },
      { fact_key: "reheating-limit", lesson_key: "practical-photo-guide", presentation: "warning", position: 2, provenance_classification: supporting, text_i18n: text("Reheat food to 74°C within no more than 2 hours, and do not reheat it more than once.", "أعد تسخين الطعام إلى 74°C خلال مدة لا تتجاوز ساعتين، ولا تعد تسخينه أكثر من مرة.", "Panaskan ulang makanan hingga 74°C dalam waktu maksimal 2 jam, dan jangan panaskan ulang lebih dari satu kali.", "भोजन को अधिकतम 2 घंटे में 74°C तक दोबारा गर्म करें और एक बार से अधिक दोबारा गर्म न करें।", "I-reheat ang pagkain sa 74°C sa loob ng hindi hihigit sa 2 oras, at huwag i-reheat nang higit sa isang beses.") },
    ],
    photo_requirements: [
      { asset_key: "cooking-poultry-temperature", purpose: "Show a poultry temperature reading without adding probe-placement instructions.", lesson_key: "overview", placement: "temperature-card", alt_i18n: text("Temperature display reading 74°C beside cooked poultry.", "شاشة حرارة تعرض 74°C بجانب دواجن مطهوة.", "Layar suhu menunjukkan 74°C di samping unggas matang.", "पकी पोल्ट्री के पास 74°C दिखाता तापमान डिस्प्ले।", "Temperature display na 74°C sa tabi ng cooked poultry."), approval_status: "needed" },
      { asset_key: "cooking-ground-meat-temperature", purpose: "Show the listed ground-meat temperature.", lesson_key: "practical-photo-guide", placement: "temperature-card", alt_i18n: text("Temperature display reading 68°C beside cooked ground meat.", "شاشة حرارة تعرض 68°C بجانب لحم مفروم مطهو.", "Layar suhu menunjukkan 68°C di samping daging giling matang.", "पके ग्राउंड मीट के पास 68°C दिखाता तापमान डिस्प्ले।", "Temperature display na 68°C sa tabi ng cooked ground meat."), approval_status: "needed" },
      { asset_key: "cooking-holding-comparison", purpose: "Compare the listed hot- and cold-holding limits.", lesson_key: "practical-photo-guide", placement: "comparison-card", alt_i18n: text("Hot-holding display at 60°C and cold-holding display at 4°C.", "شاشة حفظ ساخن عند 60°C وشاشة حفظ بارد عند 4°C.", "Layar hot holding pada 60°C dan cold holding pada 4°C.", "60°C पर गर्म होल्डिंग और 4°C पर ठंडी होल्डिंग डिस्प्ले।", "Hot-holding display sa 60°C at cold-holding display sa 4°C."), approval_status: "needed" },
      { asset_key: "cooking-reheating-reference", purpose: "Show the listed reheating target and time limit.", lesson_key: "practical-photo-guide", placement: "warning-card", alt_i18n: text("Reheating reference showing 74°C within 2 hours and one reheat only.", "مرجع إعادة تسخين يوضح 74°C خلال ساعتين وإعادة تسخين واحدة فقط.", "Referensi pemanasan ulang menunjukkan 74°C dalam 2 jam dan hanya satu kali pemanasan ulang.", "2 घंटे में 74°C और केवल एक बार दोबारा गर्म करना दिखाता संदर्भ।", "Reheating reference na nagpapakita ng 74°C sa loob ng 2 oras at isang reheat lamang."), approval_status: "needed" },
    ],
    quiz_questions: [
      { stable_key: "poultry-minimum", source_fact_keys: ["poultry-temperature"], prompt_i18n: text("What poultry temperature and time are listed?", "ما درجة حرارة ومدة طهي الدواجن المذكورة؟", "Berapa suhu dan waktu unggas yang tercantum?", "पोल्ट्री के लिए कौन-सा तापमान और समय सूचीबद्ध है?", "Ano ang nakalistang poultry temperature at oras?"), options: [option("a", text("63°C for 15 seconds", "63°C لمدة 15 ثانية", "63°C selama 15 detik", "63°C पर 15 सेकंड", "63°C sa loob ng 15 segundo")), option("b", text("68°C for 15 seconds", "68°C لمدة 15 ثانية", "68°C selama 15 detik", "68°C पर 15 सेकंड", "68°C sa loob ng 15 segundo")), option("c", text("74°C for 15 seconds", "74°C لمدة 15 ثانية", "74°C selama 15 detik", "74°C पर 15 सेकंड", "74°C sa loob ng 15 segundo"))], correct_option_key: "c", explanation_i18n: text("The current curriculum lists 74°C for at least 15 seconds.", "يذكر المنهج الحالي 74°C لمدة لا تقل عن 15 ثانية.", "Kurikulum saat ini mencantumkan 74°C selama setidaknya 15 detik.", "वर्तमान पाठ्यक्रम 74°C पर कम से कम 15 सेकंड बताता है।", "Nakalista sa kasalukuyang kurikulum ang 74°C nang hindi bababa sa 15 segundo.") },
      { stable_key: "holding-limits", source_fact_keys: ["holding-limits"], prompt_i18n: text("Which holding limits are listed?", "ما حدود الحفظ المذكورة؟", "Batas holding mana yang tercantum?", "कौन-सी होल्डिंग सीमाएँ सूचीबद्ध हैं?", "Aling holding limits ang nakalista?"), options: [option("a", text("Hot at least 60°C; cold no more than 4°C", "الساخن 60°C على الأقل؛ البارد 4°C كحد أقصى", "Panas minimal 60°C; dingin maksimal 4°C", "गर्म कम से कम 60°C; ठंडा अधिकतम 4°C", "Hot hindi bababa sa 60°C; cold hindi hihigit sa 4°C")), option("b", text("Hot at least 50°C; cold no more than 10°C", "الساخن 50°C على الأقل؛ البارد 10°C كحد أقصى", "Panas minimal 50°C; dingin maksimal 10°C", "गर्म कम से कम 50°C; ठंडा अधिकतम 10°C", "Hot hindi bababa sa 50°C; cold hindi hihigit sa 10°C")), option("c", text("Hot at least 74°C; cold no more than -18°C", "الساخن 74°C على الأقل؛ البارد -18°C كحد أقصى", "Panas minimal 74°C; dingin maksimal -18°C", "गर्म कम से कम 74°C; ठंडा अधिकतम -18°C", "Hot hindi bababa sa 74°C; cold hindi hihigit sa -18°C"))], correct_option_key: "a", explanation_i18n: text("The listed limits are 60°C for hot holding and 4°C for cold holding.", "الحدود المذكورة هي 60°C للحفظ الساخن و4°C للحفظ البارد.", "Batas yang tercantum adalah 60°C untuk hot holding dan 4°C untuk cold holding.", "सूचीबद्ध सीमाएँ गर्म होल्डिंग के लिए 60°C और ठंडी होल्डिंग के लिए 4°C हैं।", "Ang nakalistang limits ay 60°C para sa hot holding at 4°C para sa cold holding."),
      },
      { stable_key: "reheating-control", source_fact_keys: ["reheating-limit"], prompt_i18n: text("Which reheating control is listed?", "أي ضابط لإعادة التسخين مذكور؟", "Kontrol pemanasan ulang mana yang tercantum?", "कौन-सा दोबारा गर्म करने का नियंत्रण सूचीबद्ध है?", "Aling reheating control ang nakalista?"), options: [option("a", text("74°C within 2 hours, no more than once", "74°C خلال ساعتين، ولمرة واحدة فقط", "74°C dalam 2 jam, tidak lebih dari satu kali", "2 घंटे में 74°C, एक बार से अधिक नहीं", "74°C sa loob ng 2 oras, hindi hihigit sa isang beses")), option("b", text("60°C within 4 hours, unlimited repeats", "60°C خلال 4 ساعات، مع تكرار غير محدود", "60°C dalam 4 jam, pengulangan tanpa batas", "4 घंटे में 60°C, असीमित बार", "60°C sa loob ng 4 oras, walang limitasyon sa ulit")), option("c", text("68°C within 6 hours, twice", "68°C خلال 6 ساعات، مرتين", "68°C dalam 6 jam, dua kali", "6 घंटे में 68°C, दो बार", "68°C sa loob ng 6 oras, dalawang beses"))], correct_option_key: "a", explanation_i18n: text("The current curriculum lists 74°C within 2 hours and no more than one reheat.", "يذكر المنهج الحالي 74°C خلال ساعتين وعدم إعادة التسخين أكثر من مرة.", "Kurikulum saat ini mencantumkan 74°C dalam 2 jam dan tidak lebih dari satu kali pemanasan ulang.", "वर्तमान पाठ्यक्रम 2 घंटे में 74°C और एक से अधिक बार दोबारा गर्म न करना बताता है।", "Nakalista sa kasalukuyang kurikulum ang 74°C sa loob ng 2 oras at hindi hihigit sa isang reheat."),
      },
    ],
  },
  {
    stable_key: "waste-management",
    position: 8,
    category_key: "hygiene",
    source_module_ids: ["waste-management"],
    default_provenance_classification: supporting,
    title_i18n: text("Waste Management", "إدارة النفايات", "Pengelolaan Sampah", "कचरा प्रबंधन", "Pamamahala ng Basura"),
    description_i18n: text("Bin, liner, dumpster, and grease-trap controls from the current Training curriculum.", "ضوابط الحاويات والأكياس والحاوية الخارجية ومصيدة الدهون من منهج التدريب الحالي.", "Kontrol tempat sampah, liner, dumpster, dan grease trap dari kurikulum Pelatihan saat ini.", "वर्तमान प्रशिक्षण पाठ्यक्रम से डिब्बे, लाइनर, डंपस्टर और ग्रीस ट्रैप नियंत्रण।", "Bin, liner, dumpster, at grease-trap controls mula sa kasalukuyang kurikulum."),
    lesson_objectives_i18n: {
      overview: text("Recognize the current waste-container and external-dumpster controls.", "التعرّف على ضوابط حاويات النفايات والحاوية الخارجية الحالية.", "Mengenali kontrol tempat sampah dan dumpster luar saat ini.", "वर्तमान कचरा पात्र और बाहरी डंपस्टर नियंत्रण पहचानें।", "Kilalanin ang kasalukuyang waste-container at external-dumpster controls."),
      practical_photo_guide: text("Use photo checklists for bin fill, liners, dumpsters, and grease traps.", "استخدام قوائم مصورة لامتلاء الحاوية والأكياس والحاويات الخارجية ومصائد الدهون.", "Menggunakan daftar foto untuk isi tempat sampah, liner, dumpster, dan grease trap.", "डिब्बे के भराव, लाइनर, डंपस्टर और ग्रीस ट्रैप के लिए फोटो चेकलिस्ट उपयोग करें।", "Gumamit ng photo checklists para sa bin fill, liners, dumpsters, at grease traps."),
      knowledge_check: text("Check bin features, emptying level, and external controls.", "التحقق من خصائص الحاوية ومستوى التفريغ والضوابط الخارجية.", "Memeriksa fitur tempat sampah, tingkat pengosongan, dan kontrol luar.", "डिब्बे की विशेषताएँ, खाली करने का स्तर और बाहरी नियंत्रण जाँचें।", "Suriin ang bin features, emptying level, at external controls."),
    },
    practical_mode: "reference",
    facts: [
      { fact_key: "bin-features", lesson_key: "overview", presentation: "key_point", position: 1, provenance_classification: supporting, text_i18n: text("Kitchen bins must be leak-proof, washable, and fitted with a pedal-operated lid.", "يجب أن تكون حاويات المطبخ مانعة للتسرب وقابلة للغسل ومزودة بغطاء يعمل بالدواسة.", "Tempat sampah dapur harus anti-bocor, dapat dicuci, dan memiliki tutup berpedal.", "रसोई डिब्बे रिसाव-रोधी, धोने योग्य और पैडल से चलने वाले ढक्कन वाले होने चाहिए।", "Dapat leak-proof, washable, at may pedal-operated lid ang kitchen bins.") },
      { fact_key: "thick-liner", lesson_key: "practical-photo-guide", presentation: "key_point", position: 1, provenance_classification: supporting, text_i18n: text("Use a thick waste-bag liner.", "استخدم كيس نفايات سميكاً.", "Gunakan liner kantong sampah yang tebal.", "मोटा कचरा-बैग लाइनर उपयोग करें।", "Gumamit ng makapal na waste-bag liner.") },
      { fact_key: "empty-three-quarters", lesson_key: "practical-photo-guide", presentation: "warning", position: 2, provenance_classification: supporting, text_i18n: text("Empty the bin when it reaches three-quarters full; do not compress waste with hands or feet.", "أفرغ الحاوية عندما تمتلئ إلى ثلاثة أرباعها؛ ولا تضغط النفايات باليدين أو القدمين.", "Kosongkan tempat sampah saat terisi tiga perempat; jangan tekan sampah dengan tangan atau kaki.", "डिब्बा तीन-चौथाई भरने पर खाली करें; हाथ या पैर से कचरा न दबाएँ।", "Alisan ang bin kapag tatlong-kapat na puno; huwag siksikin ang basura gamit ang kamay o paa.") },
      { fact_key: "covered-dumpster", lesson_key: "practical-photo-guide", presentation: "key_point", position: 3, provenance_classification: supporting, text_i18n: text("Keep the external dumpster tightly covered and a safe distance from the kitchen door.", "أبقِ الحاوية الخارجية مغلقة بإحكام وعلى مسافة آمنة من باب المطبخ.", "Jaga dumpster luar tetap tertutup rapat dan berjarak aman dari pintu dapur.", "बाहरी डंपस्टर कसकर ढका और रसोई के दरवाज़े से सुरक्षित दूरी पर रखें।", "Panatilihing mahigpit ang takip ng external dumpster at ligtas ang layo mula sa kitchen door.") },
      { fact_key: "grease-trap-schedule", lesson_key: "practical-photo-guide", presentation: "key_point", position: 4, provenance_classification: supporting, text_i18n: text("Clean the grease trap on a schedule to prevent blockage and odor.", "نظّف مصيدة الدهون وفق جدول لمنع الانسداد والروائح.", "Bersihkan grease trap sesuai jadwal untuk mencegah penyumbatan dan bau.", "रुकावट और दुर्गंध रोकने के लिए ग्रीस ट्रैप को समय-सारणी के अनुसार साफ करें।", "Linisin ang grease trap ayon sa iskedyul upang maiwasan ang bara at amoy.") },
    ],
    photo_requirements: [
      { asset_key: "waste-pedal-bin", purpose: "Show the listed kitchen-bin features.", lesson_key: "overview", placement: "overview-hero", alt_i18n: text("Leak-proof washable kitchen bin with a pedal-operated lid and thick liner.", "حاوية مطبخ مانعة للتسرب وقابلة للغسل بغطاء يعمل بالدواسة وكيس سميك.", "Tempat sampah dapur anti-bocor dan dapat dicuci dengan tutup pedal serta liner tebal.", "पैडल ढक्कन और मोटे लाइनर वाला रिसाव-रोधी धोने योग्य रसोई डिब्बा।", "Leak-proof at washable na kitchen bin na may pedal-operated lid at makapal na liner."), approval_status: "needed" },
      { asset_key: "waste-three-quarter-level", purpose: "Show the current emptying threshold.", lesson_key: "practical-photo-guide", placement: "warning-card", alt_i18n: text("Kitchen waste bin filled to the three-quarter level without compressed waste.", "حاوية نفايات مطبخ ممتلئة إلى مستوى ثلاثة أرباع من دون ضغط النفايات.", "Tempat sampah dapur terisi hingga tiga perempat tanpa sampah yang ditekan.", "बिना दबाए कचरे के साथ तीन-चौथाई भरा रसोई कचरा डिब्बा।", "Kitchen waste bin na tatlong-kapat ang laman at hindi siksik ang basura."), approval_status: "needed" },
      { asset_key: "waste-covered-dumpster", purpose: "Show a covered dumpster away from the kitchen door.", lesson_key: "practical-photo-guide", placement: "reference-card", alt_i18n: text("Tightly covered external dumpster positioned away from the kitchen door.", "حاوية خارجية مغلقة بإحكام وبعيدة عن باب المطبخ.", "Dumpster luar tertutup rapat dan ditempatkan jauh dari pintu dapur.", "रसोई दरवाज़े से दूर कसकर ढका बाहरी डंपस्टर।", "Mahigpit na nakatakip na external dumpster na malayo sa kitchen door."), approval_status: "needed" },
      { asset_key: "waste-grease-trap", purpose: "Show a grease trap identified for scheduled cleaning.", lesson_key: "practical-photo-guide", placement: "checklist-card", alt_i18n: text("Grease trap marked for scheduled cleaning.", "مصيدة دهون محددة للتنظيف المجدول.", "Grease trap ditandai untuk pembersihan terjadwal.", "निर्धारित सफाई के लिए चिह्नित ग्रीस ट्रैप।", "Grease trap na minarkahan para sa scheduled cleaning."), approval_status: "needed" },
    ],
    quiz_questions: [
      { stable_key: "bin-emptying-level", source_fact_keys: ["empty-three-quarters"], prompt_i18n: text("When should the kitchen bin be emptied?", "متى يجب إفراغ حاوية المطبخ؟", "Kapan tempat sampah dapur harus dikosongkan?", "रसोई डिब्बा कब खाली करना चाहिए?", "Kailan dapat alisan ang kitchen bin?"), options: [option("a", text("At one-quarter full", "عند امتلائه إلى الربع", "Saat seperempat penuh", "एक-चौथाई भरने पर", "Kapag isang-kapat na puno")), option("b", text("At three-quarters full", "عند امتلائه إلى ثلاثة أرباع", "Saat tiga perempat penuh", "तीन-चौथाई भरने पर", "Kapag tatlong-kapat na puno")), option("c", text("Only when overflowing", "فقط عند الفيضان", "Hanya saat meluap", "केवल बहने पर", "Kapag umaapaw lamang"))], correct_option_key: "b", explanation_i18n: text("The current curriculum sets the emptying level at three-quarters full.", "يحدد المنهج الحالي مستوى التفريغ عند ثلاثة أرباع الامتلاء.", "Kurikulum saat ini menetapkan pengosongan saat tiga perempat penuh.", "वर्तमान पाठ्यक्रम तीन-चौथाई भरने पर खाली करने को कहता है।", "Itinatakda ng kasalukuyang kurikulum ang pag-alis kapag tatlong-kapat na puno."),
      },
      { stable_key: "bin-required-feature", source_fact_keys: ["bin-features"], prompt_i18n: text("Which feature is listed for a kitchen bin?", "أي خاصية مذكورة لحاوية المطبخ؟", "Fitur apa yang tercantum untuk tempat sampah dapur?", "रसोई डिब्बे के लिए कौन-सी विशेषता सूचीबद्ध है?", "Aling feature ang nakalista para sa kitchen bin?"), options: [option("a", text("Open top", "غطاء مفتوح", "Bagian atas terbuka", "खुला ऊपर", "Open top")), option("b", text("Pedal-operated lid", "غطاء يعمل بالدواسة", "Tutup berpedal", "पैडल से चलने वाला ढक्कन", "Pedal-operated lid")), option("c", text("Cardboard body", "هيكل من الكرتون", "Badan kardus", "गत्ते का शरीर", "Cardboard body"))], correct_option_key: "b", explanation_i18n: text("The current curriculum lists a pedal-operated lid.", "يذكر المنهج الحالي غطاء يعمل بالدواسة.", "Kurikulum saat ini mencantumkan tutup berpedal.", "वर्तमान पाठ्यक्रम पैडल से चलने वाला ढक्कन बताता है।", "Nakalista sa kasalukuyang kurikulum ang pedal-operated lid."),
      },
      { stable_key: "dumpster-control", source_fact_keys: ["covered-dumpster"], prompt_i18n: text("How should the external dumpster be kept?", "كيف يجب الحفاظ على الحاوية الخارجية؟", "Bagaimana dumpster luar harus dijaga?", "बाहरी डंपस्टर कैसे रखना चाहिए?", "Paano dapat panatilihin ang external dumpster?"), options: [option("a", text("Open beside the kitchen door", "مفتوحة بجانب باب المطبخ", "Terbuka di samping pintu dapur", "रसोई दरवाज़े के पास खुला", "Bukas sa tabi ng kitchen door")), option("b", text("Tightly covered and safely away from the kitchen door", "مغلقة بإحكام وبعيدة بأمان عن باب المطبخ", "Tertutup rapat dan berjarak aman dari pintu dapur", "कसकर ढका और रसोई दरवाज़े से सुरक्षित दूरी पर", "Mahigpit na nakatakip at ligtas ang layo sa kitchen door")), option("c", text("Inside the preparation area", "داخل منطقة التحضير", "Di dalam area persiapan", "तैयारी क्षेत्र के अंदर", "Sa loob ng preparation area"))], correct_option_key: "b", explanation_i18n: text("The current curriculum requires a tight cover and safe distance from the kitchen door.", "يشترط المنهج الحالي غطاء محكماً ومسافة آمنة من باب المطبخ.", "Kurikulum saat ini mensyaratkan penutup rapat dan jarak aman dari pintu dapur.", "वर्तमान पाठ्यक्रम कसकर ढकने और रसोई दरवाज़े से सुरक्षित दूरी की माँग करता है।", "Kailangan sa kasalukuyang kurikulum ang mahigpit na takip at ligtas na layo mula sa kitchen door."),
      },
    ],
  },
  {
    stable_key: "pest-prevention-escalation",
    position: 9,
    category_key: "hygiene",
    source_module_ids: ["pest-control"],
    default_provenance_classification: supporting,
    title_i18n: text("Pest Prevention & Escalation", "الوقاية من الآفات والتصعيد", "Pencegahan & Eskalasi Hama", "कीट रोकथाम और एस्केलेशन", "Pag-iwas at Eskalasyon ng Peste"),
    description_i18n: text("Access prevention, pest evidence, housekeeping, and authorized PCO escalation from the current Training curriculum.", "منع الدخول وأدلة الآفات والنظافة والتصعيد إلى شركة مكافحة معتمدة من منهج التدريب الحالي.", "Pencegahan akses, bukti hama, kebersihan area, dan eskalasi ke PCO resmi dari kurikulum Pelatihan saat ini.", "वर्तमान प्रशिक्षण पाठ्यक्रम से प्रवेश रोकथाम, कीट संकेत, हाउसकीपिंग और अधिकृत PCO तक एस्केलेशन।", "Access prevention, pest evidence, housekeeping, at authorized PCO escalation mula sa kasalukuyang kurikulum."),
    lesson_objectives_i18n: {
      overview: text("Recognize the current access-prevention and authorized-treatment controls.", "التعرّف على ضوابط منع الدخول والمعالجة المصرح بها الحالية.", "Mengenali kontrol pencegahan akses dan penanganan resmi saat ini.", "वर्तमान प्रवेश-रोकथाम और अधिकृत उपचार नियंत्रण पहचानें।", "Kilalanin ang kasalukuyang access-prevention at authorized-treatment controls."),
      practical_photo_guide: text("Use photo references to identify barriers, housekeeping issues, and pest evidence.", "استخدام مراجع مصورة للتعرّف على الحواجز ومشكلات النظافة وأدلة الآفات.", "Menggunakan referensi foto untuk mengenali penghalang, masalah kebersihan, dan bukti hama.", "अवरोध, हाउसकीपिंग समस्याएँ और कीट संकेत पहचानने के लिए फोटो संदर्भ उपयोग करें।", "Gumamit ng photo references para matukoy ang barriers, housekeeping issues, at pest evidence."),
      knowledge_check: text("Check door-gap, authorized-treatment, and pest-evidence decisions.", "التحقق من قرارات فجوة الباب والمعالجة المصرح بها وأدلة الآفات.", "Memeriksa keputusan celah pintu, penanganan resmi, dan bukti hama.", "दरवाज़ा अंतर, अधिकृत उपचार और कीट संकेत संबंधी निर्णय जाँचें।", "Suriin ang door-gap, authorized-treatment, at pest-evidence decisions."),
    },
    practical_mode: "reference",
    facts: [
      { fact_key: "rear-door-gap", lesson_key: "overview", presentation: "key_point", position: 1, provenance_classification: supporting, text_i18n: text("Keep the rear door self-closing with a bottom gap no greater than 6 mm.", "اجعل الباب الخلفي ذاتي الإغلاق وبفجوة سفلية لا تتجاوز 6 mm.", "Jaga pintu belakang menutup sendiri dengan celah bawah tidak lebih dari 6 mm.", "पीछे का दरवाज़ा स्वयं बंद होने वाला रखें और नीचे का अंतर 6 mm से अधिक न हो।", "Panatilihing self-closing ang rear door at hindi hihigit sa 6 mm ang bottom gap."),
      },
      { fact_key: "air-curtain", lesson_key: "overview", presentation: "key_point", position: 2, provenance_classification: supporting, text_i18n: text("Keep the air curtain active while the receiving or service door is open.", "أبقِ الستارة الهوائية فعالة أثناء فتح باب الاستلام أو الخدمة.", "Aktifkan air curtain saat pintu receiving atau servis terbuka.", "प्राप्ति या सेवा दरवाज़ा खुला हो तो एयर कर्टेन सक्रिय रखें।", "Panatilihing aktibo ang air curtain habang bukas ang receiving o service door."),
      },
      { fact_key: "remove-cardboard", lesson_key: "practical-photo-guide", presentation: "warning", position: 1, provenance_classification: supporting, text_i18n: text("Do not keep used cardboard in the kitchen for too long.", "لا تحتفظ بالكرتون المستخدم في المطبخ مدة طويلة.", "Jangan simpan kardus bekas terlalu lama di dapur.", "उपयोग किया गत्ता रसोई में बहुत देर तक न रखें।", "Huwag mag-imbak nang matagal ng ginamit na cardboard sa kusina."),
      },
      { fact_key: "authorized-pco", lesson_key: "practical-photo-guide", presentation: "warning", position: 2, provenance_classification: supporting, text_i18n: text("Only an authorized PCO may apply poison or fumigation, and only while the restaurant is not operating.", "لا يجوز استخدام السم أو التبخير إلا بواسطة شركة مكافحة آفات معتمدة وعندما لا يكون المطعم قيد التشغيل.", "Hanya PCO resmi yang boleh menggunakan racun atau fumigasi, dan hanya saat restoran tidak beroperasi.", "केवल अधिकृत PCO ही ज़हर या फ्यूमिगेशन लागू कर सकता है और वह भी रेस्तरां बंद होने पर।", "Authorized PCO lamang ang maaaring gumamit ng poison o fumigation, at habang hindi nag-ooperate ang restaurant."),
      },
      { fact_key: "pest-signs", lesson_key: "practical-photo-guide", presentation: "key_point", position: 3, provenance_classification: supporting, text_i18n: text("Listed pest signs include rodent droppings, gnaw marks, cockroach odor, ootheca, and fly larvae.", "تشمل علامات الآفات المذكورة فضلات القوارض وآثار القضم ورائحة الصراصير وأكياس البيض ويرقات الذباب.", "Tanda hama yang tercantum meliputi kotoran tikus, bekas gigitan, bau kecoa, ootheca, dan larva lalat.", "सूचीबद्ध कीट संकेतों में कृंतक मल, कुतरने के निशान, तिलचट्टे की गंध, ऊथेका और मक्खी के लार्वा शामिल हैं।", "Kabilang sa nakalistang pest signs ang rodent droppings, gnaw marks, amoy-ipis, ootheca, at fly larvae."),
      },
      { fact_key: "aerosol-risk", lesson_key: "overview", presentation: "scenario", position: 3, provenance_classification: supporting, text_i18n: text("The current curriculum identifies toxic chemical contamination of food and equipment as the risk when staff spray insect aerosol in an active kitchen.", "يحدد المنهج الحالي تلوث الطعام والمعدات بمواد كيميائية سامة بوصفه خطر رش الموظفين مبيداً حشرياً في مطبخ يعمل.", "Kurikulum saat ini mengidentifikasi kontaminasi bahan kimia beracun pada makanan dan peralatan sebagai risiko ketika staf menyemprot aerosol serangga di dapur aktif.", "वर्तमान पाठ्यक्रम सक्रिय रसोई में कर्मचारी द्वारा कीट एरोसोल छिड़कने पर भोजन और उपकरण के विषैले रासायनिक संदूषण को जोखिम बताता है।", "Tinutukoy ng kasalukuyang kurikulum ang toxic chemical contamination ng pagkain at kagamitan bilang panganib kapag nag-spray ang staff ng insect aerosol sa aktibong kusina."),
      },
    ],
    photo_requirements: [
      { asset_key: "pest-door-gap", purpose: "Show the current rear-door gap limit.", lesson_key: "overview", placement: "measurement-reference", alt_i18n: text("Self-closing rear door with the bottom gap measured at no more than 6 mm.", "باب خلفي ذاتي الإغلاق وفجوته السفلية مقاسة بما لا يزيد على 6 mm.", "Pintu belakang yang menutup sendiri dengan celah bawah diukur tidak lebih dari 6 mm.", "स्वयं बंद होने वाला पीछे का दरवाज़ा, नीचे का अंतर 6 mm से अधिक नहीं।", "Self-closing rear door na may bottom gap na hindi hihigit sa 6 mm."), approval_status: "needed" },
      { asset_key: "pest-air-curtain", purpose: "Show an active air curtain at an open service door.", lesson_key: "practical-photo-guide", placement: "reference-card", alt_i18n: text("Active air curtain above an open receiving door.", "ستارة هوائية فعالة فوق باب استلام مفتوح.", "Air curtain aktif di atas pintu receiving yang terbuka.", "खुले प्राप्ति दरवाज़े के ऊपर सक्रिय एयर कर्टेन।", "Aktibong air curtain sa ibabaw ng bukas na receiving door."), approval_status: "needed" },
      { asset_key: "pest-housekeeping-cardboard", purpose: "Show used cardboard removed from the kitchen.", lesson_key: "practical-photo-guide", placement: "warning-card", alt_i18n: text("Used cardboard being removed from the kitchen area.", "كرتون مستخدم يُزال من منطقة المطبخ.", "Kardus bekas dipindahkan dari area dapur.", "उपयोग किया गत्ता रसोई क्षेत्र से हटाया जा रहा है।", "Ginamit na cardboard na inaalis mula sa kitchen area."), approval_status: "needed" },
      { asset_key: "pest-evidence", purpose: "Show only the pest signs already listed in the current curriculum.", lesson_key: "practical-photo-guide", placement: "evidence-cards", alt_i18n: text("Reference examples of rodent droppings, gnaw marks, ootheca, and fly larvae.", "أمثلة مرجعية لفضلات القوارض وآثار القضم وأكياس البيض ويرقات الذباب.", "Contoh referensi kotoran tikus, bekas gigitan, ootheca, dan larva lalat.", "कृंतक मल, कुतरने के निशान, ऊथेका और मक्खी लार्वा के संदर्भ उदाहरण।", "Reference examples ng rodent droppings, gnaw marks, ootheca, at fly larvae."), approval_status: "needed" },
    ],
    quiz_questions: [
      { stable_key: "rear-door-gap", source_fact_keys: ["rear-door-gap"], prompt_i18n: text("What maximum bottom gap is listed for the rear door?", "ما أقصى فجوة سفلية مذكورة للباب الخلفي؟", "Berapa celah bawah maksimum yang tercantum untuk pintu belakang?", "पीछे के दरवाज़े के लिए सूचीबद्ध अधिकतम निचला अंतर क्या है?", "Ano ang nakalistang maximum bottom gap para sa rear door?"), options: [option("a", text("6 mm", "6 mm", "6 mm", "6 mm", "6 mm")), option("b", text("12 mm", "12 mm", "12 mm", "12 mm", "12 mm")), option("c", text("20 mm", "20 mm", "20 mm", "20 mm", "20 mm"))], correct_option_key: "a", explanation_i18n: text("The current curriculum lists no more than 6 mm.", "يذكر المنهج الحالي ما لا يزيد على 6 mm.", "Kurikulum saat ini mencantumkan tidak lebih dari 6 mm.", "वर्तमान पाठ्यक्रम 6 mm से अधिक नहीं बताता है।", "Nakalista sa kasalukuyang kurikulum ang hindi hihigit sa 6 mm."),
      },
      { stable_key: "pesticide-authority", source_fact_keys: ["authorized-pco"], prompt_i18n: text("Who may apply poison or fumigation?", "من يجوز له استخدام السم أو التبخير؟", "Siapa yang boleh menggunakan racun atau fumigasi?", "ज़हर या फ्यूमिगेशन कौन लागू कर सकता है?", "Sino ang maaaring gumamit ng poison o fumigation?"), options: [option("a", text("Any kitchen employee", "أي موظف مطبخ", "Setiap karyawan dapur", "कोई भी रसोई कर्मचारी", "Sinumang kitchen employee")), option("b", text("An authorized PCO while the restaurant is not operating", "شركة مكافحة آفات معتمدة عندما لا يعمل المطعم", "PCO resmi saat restoran tidak beroperasi", "रेस्तरां बंद होने पर अधिकृत PCO", "Authorized PCO habang hindi nag-ooperate ang restaurant")), option("c", text("The cashier during service", "الكاشير أثناء الخدمة", "Kasir saat layanan", "सेवा के दौरान कैशियर", "Cashier habang may service"))], correct_option_key: "b", explanation_i18n: text("The current curriculum restricts poison and fumigation to an authorized PCO outside operating hours.", "يقصر المنهج الحالي استخدام السم والتبخير على شركة مكافحة معتمدة خارج ساعات التشغيل.", "Kurikulum saat ini membatasi racun dan fumigasi pada PCO resmi di luar jam operasional.", "वर्तमान पाठ्यक्रम ज़हर और फ्यूमिगेशन को संचालन समय के बाहर अधिकृत PCO तक सीमित करता है।", "Nililimitahan ng kasalukuyang kurikulum ang poison at fumigation sa authorized PCO sa labas ng operating hours."),
      },
      { stable_key: "pest-evidence-example", source_fact_keys: ["pest-signs"], prompt_i18n: text("Which is a listed sign of pest activity?", "أي مما يلي علامة مذكورة لنشاط الآفات؟", "Mana yang merupakan tanda aktivitas hama yang tercantum?", "कौन-सा कीट गतिविधि का सूचीबद्ध संकेत है?", "Alin ang nakalistang tanda ng pest activity?"), options: [option("a", text("Rodent droppings", "فضلات القوارض", "Kotoran tikus", "कृंतक मल", "Rodent droppings")), option("b", text("A clean sealed container", "حاوية نظيفة محكمة", "Wadah bersih tertutup", "साफ सीलबंद पात्र", "Malinis na sealed container")), option("c", text("A completed temperature log", "سجل حرارة مكتمل", "Log suhu lengkap", "पूरा तापमान लॉग", "Kumpletong temperature log"))], correct_option_key: "a", explanation_i18n: text("Rodent droppings are one of the pest signs listed in the current curriculum.", "فضلات القوارض من علامات الآفات المذكورة في المنهج الحالي.", "Kotoran tikus adalah salah satu tanda hama yang tercantum dalam kurikulum saat ini.", "कृंतक मल वर्तमान पाठ्यक्रम में सूचीबद्ध कीट संकेतों में से एक है।", "Ang rodent droppings ay isa sa pest signs na nakalista sa kasalukuyang kurikulum."),
      },
    ],
  },
];

function localizedFactContent(module: ModuleSource, lessonKey: "overview" | "practical-photo-guide") {
  return Object.fromEntries(
    trainingLocales.map((locale) => [
      locale,
      {
        content_schema_version: 1,
        layout: "photo_first",
        mode: lessonKey === "overview" ? "reference" : module.practical_mode,
        items: module.facts
          .filter((fact) => fact.lesson_key === lessonKey)
          .sort((left, right) => left.position - right.position)
          .map((fact) => ({
            fact_key: fact.fact_key,
            presentation: fact.presentation,
            position: fact.position,
            text: fact.text_i18n[locale],
            provenance_classification: fact.provenance_classification,
          })),
      },
    ]),
  ) as Record<TrainingLocale, object>;
}

function localizedQuizContent(module: ModuleSource) {
  return Object.fromEntries(
    trainingLocales.map((locale) => [
      locale,
      {
        content_schema_version: 1,
        questions: module.quiz_questions.map((question) => ({
          stable_key: question.stable_key,
          source_fact_keys: question.source_fact_keys,
          prompt: question.prompt_i18n[locale],
          options: question.options.map((answerOption) => ({
            option_key: answerOption.option_key,
            text: answerOption.text_i18n[locale],
          })),
          explanation: question.explanation_i18n[locale],
        })),
      },
    ]),
  ) as Record<TrainingLocale, object>;
}

const seedModules = modules.map((module) => ({
  stable_key: module.stable_key,
  position: module.position,
  category_key: module.category_key,
  title_i18n: module.title_i18n,
  description_i18n: module.description_i18n,
  metadata: {
    curriculum_status: "draft",
    translation_review_status: "draft",
    default_provenance_classification: module.default_provenance_classification,
    source_module_ids: module.source_module_ids,
    provenance_facts: module.facts.map((fact) => ({
      fact_key: fact.fact_key,
      provenance_classification: fact.provenance_classification,
      source_module_ids: module.source_module_ids,
    })),
    photo_requirements: module.photo_requirements,
  },
  lessons: [
    {
      stable_key: "overview",
      position: 1,
      lesson_type: "reading",
      required: true,
      title_i18n: sharedLessonTitles.overview,
      objective_i18n: module.lesson_objectives_i18n.overview,
      content_i18n: localizedFactContent(module, "overview"),
      estimated_duration_seconds: 240,
      minimum_engagement_seconds: 0,
      pass_threshold_bps: null,
      metadata: {
        content_schema_version: 1,
        curriculum_status: "draft",
        translation_review_status: "draft",
        provenance_fact_keys: module.facts.filter((fact) => fact.lesson_key === "overview").map((fact) => fact.fact_key),
      },
    },
    {
      stable_key: "practical-photo-guide",
      position: 2,
      lesson_type: "key_points",
      required: true,
      title_i18n: sharedLessonTitles.practical,
      objective_i18n: module.lesson_objectives_i18n.practical_photo_guide,
      content_i18n: localizedFactContent(module, "practical-photo-guide"),
      estimated_duration_seconds: 300,
      minimum_engagement_seconds: 0,
      pass_threshold_bps: null,
      metadata: {
        content_schema_version: 1,
        curriculum_status: "draft",
        translation_review_status: "draft",
        practical_mode: module.practical_mode,
        provenance_fact_keys: module.facts.filter((fact) => fact.lesson_key === "practical-photo-guide").map((fact) => fact.fact_key),
        photo_requirement_keys: module.photo_requirements.map((photo) => photo.asset_key),
      },
    },
    {
      stable_key: "knowledge-check",
      position: 3,
      lesson_type: "quiz",
      required: true,
      title_i18n: sharedLessonTitles.quiz,
      objective_i18n: module.lesson_objectives_i18n.knowledge_check,
      content_i18n: localizedQuizContent(module),
      estimated_duration_seconds: 240,
      minimum_engagement_seconds: 0,
      pass_threshold_bps: 8000,
      metadata: {
        content_schema_version: 1,
        curriculum_status: "draft",
        translation_review_status: "draft",
        answer_key_by_question: Object.fromEntries(
          module.quiz_questions.map((question) => [question.stable_key, question.correct_option_key]),
        ),
        question_provenance: module.quiz_questions.map((question) => ({
          stable_key: question.stable_key,
          source_fact_keys: question.source_fact_keys,
          provenance_classifications: [
            ...new Set(
              question.source_fact_keys.map((factKey) => {
                const fact = module.facts.find((candidate) => candidate.fact_key === factKey);
                if (!fact) throw new Error(`Unknown fact ${module.stable_key}:${factKey}`);
                return fact.provenance_classification;
              }),
            ),
          ],
        })),
      },
    },
  ],
}));

export const baladiyahDraftCurriculum = {
  manifest_schema_version: 1,
  curriculum_status: "draft",
  translation_review_status: "draft",
  regulatory_status: "unverified_supporting_content",
  course: {
    course_key: "baladiyah-food-safety-hygiene",
    version_number: 1,
    status: "draft",
    default_locale: "en",
    supported_locales: trainingLocales,
    title_i18n: text(
      "Baladiyah Food Safety & Hygiene",
      "سلامة الغذاء والنظافة - البلدية",
      "Keamanan Pangan & Kebersihan Baladiyah",
      "Baladiyah खाद्य सुरक्षा और स्वच्छता",
      "Baladiyah Food Safety at Kalinisan",
    ),
    description_i18n: text(
      "Draft photo-first curriculum rebuilt from the current Training content. Supporting modules are not yet verified as official Baladiyah regulations.",
      "منهج مسودة يعتمد على الصور وأُعيد بناؤه من محتوى التدريب الحالي. لم يتم بعد التحقق من الوحدات الداعمة بوصفها لوائح بلدية رسمية.",
      "Draf kurikulum berbasis foto yang dibangun ulang dari konten Pelatihan saat ini. Modul pendukung belum diverifikasi sebagai peraturan resmi Baladiyah.",
      "वर्तमान प्रशिक्षण सामग्री से पुनर्निर्मित फोटो-प्रथम मसौदा पाठ्यक्रम। सहायक मॉड्यूल अभी आधिकारिक Baladiyah नियमों के रूप में सत्यापित नहीं हैं।",
      "Draft na photo-first curriculum na muling binuo mula sa kasalukuyang Training content. Hindi pa beripikadong opisyal na Baladiyah regulation ang supporting modules.",
    ),
  },
  excluded_source_modules: [
    {
      stable_key: "restaurant-safety",
      disposition: "reserved_for_future_internal_restaurant_safety_course",
      provenance_classification: "internal_operational" as const,
    },
  ],
  modules: seedModules,
} as const;
