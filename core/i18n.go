package main

// lang is the UI language (set_lang). The core only produces a handful of
// words itself: labels for message kinds that end up in previews and quotes.
var lang = "en"

var words = map[string]map[string]string{
	"tr": {"You": "Sen", "Group": "Grup", "Photo": "Fotoğraf", "Video": "Video", "Voice message": "Sesli mesaj", "Sticker": "Çıkartma",
		"Contact": "Kişi", "Contacts": "Kişiler", "Location": "Konum", "Live location": "Canlı konum", "Poll": "Anket", "Call": "Arama", "Group invite": "Grup daveti"},
	"ru": {"You": "Вы", "Group": "Группа", "Photo": "Фото", "Video": "Видео", "Voice message": "Голосовое сообщение", "Sticker": "Стикер",
		"Contact": "Контакт", "Contacts": "Контакты", "Location": "Местоположение", "Live location": "Геоданные в реальном времени", "Poll": "Опрос", "Call": "Звонок", "Group invite": "Приглашение в группу"},
	"fr": {"You": "Vous", "Group": "Groupe", "Photo": "Photo", "Video": "Vidéo", "Voice message": "Message vocal", "Sticker": "Sticker",
		"Contact": "Contact", "Contacts": "Contacts", "Location": "Localisation", "Live location": "Localisation en direct", "Poll": "Sondage", "Call": "Appel", "Group invite": "Invitation de groupe"},
	"de": {"You": "Du", "Group": "Gruppe", "Photo": "Foto", "Video": "Video", "Voice message": "Sprachnachricht", "Sticker": "Sticker",
		"Contact": "Kontakt", "Contacts": "Kontakte", "Location": "Standort", "Live location": "Live-Standort", "Poll": "Umfrage", "Call": "Anruf", "Group invite": "Gruppeneinladung"},
	"es": {"You": "Tú", "Group": "Grupo", "Photo": "Foto", "Video": "Video", "Voice message": "Mensaje de voz", "Sticker": "Sticker",
		"Contact": "Contacto", "Contacts": "Contactos", "Location": "Ubicación", "Live location": "Ubicación en tiempo real", "Poll": "Encuesta", "Call": "Llamada", "Group invite": "Invitación al grupo"},
	"pt": {"You": "Você", "Group": "Grupo", "Photo": "Foto", "Video": "Vídeo", "Voice message": "Mensagem de voz", "Sticker": "Figurinha",
		"Contact": "Contato", "Contacts": "Contatos", "Location": "Localização", "Live location": "Localização em tempo real", "Poll": "Enquete", "Call": "Chamada", "Group invite": "Convite para o grupo"},
	"it": {"You": "Tu", "Group": "Gruppo", "Photo": "Foto", "Video": "Video", "Voice message": "Messaggio vocale", "Sticker": "Sticker",
		"Contact": "Contatto", "Contacts": "Contatti", "Location": "Posizione", "Live location": "Posizione in tempo reale", "Poll": "Sondaggio", "Call": "Chiamata", "Group invite": "Invito al gruppo"},
	"ar": {"You": "أنت", "Group": "مجموعة", "Photo": "صورة", "Video": "فيديو", "Voice message": "رسالة صوتية", "Sticker": "ملصق",
		"Contact": "جهة اتصال", "Contacts": "جهات اتصال", "Location": "الموقع", "Live location": "الموقع المباشر", "Poll": "استطلاع", "Call": "مكالمة", "Group invite": "دعوة إلى مجموعة"},
}

// T translates one of the core's own words; unknown languages get English.
func T(key string) string {
	if w, ok := words[lang][key]; ok {
		return w
	}
	return key
}
